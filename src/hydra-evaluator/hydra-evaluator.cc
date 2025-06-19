#include "db.hh"
#include "hydra-config.hh"
#include "lix/libmain/shared.hh"
#include "lix/libutil/logging.hh"
#include "lix/libutil/pool.hh"
#include "lix/libutil/signals.hh"
#include "lix/libutil/async.hh"

#include <algorithm>
#include <thread>
#include <cstring>
#include <optional>

#include <sys/types.h>
#include <sys/wait.h>

#include <boost/format.hpp>
#include <utility>

using namespace nix;
using boost::format;

using JobsetName = std::pair<std::string, std::string>;

class JobsetId {
    public:

    std::string project;
    std::string jobset;
    int id;


    JobsetId(std::string  project, std::string  jobset, int id)
        : project{std::move( project )}, jobset{std::move( jobset )}, id{ id }
    {
    }

    friend bool operator== (const JobsetId & lhs, const JobsetId & rhs);
    friend bool operator!= (const JobsetId & lhs, const JobsetId & rhs);
    friend bool operator< (const JobsetId & lhs, const JobsetId & rhs);


    friend bool operator== (const JobsetId & lhs, const JobsetName & rhs);
    friend bool operator!= (const JobsetId & lhs, const JobsetName & rhs);

    [[nodiscard]] std::string display() const {
        return str(format("%1%:%2% (jobset#%3%)") % project % jobset % id);
    }
};
bool operator==(const JobsetId & lhs, const JobsetId & rhs)
{
    return lhs.id == rhs.id;
}

bool operator!=(const JobsetId & lhs, const JobsetId & rhs)
{
    return lhs.id != rhs.id;
}

bool operator<(const JobsetId & lhs, const JobsetId & rhs)
{
    return lhs.id < rhs.id;
}

bool operator==(const JobsetId & lhs, const JobsetName & rhs)
{
    return lhs.project == rhs.first && lhs.jobset == rhs.second;
}

bool operator!=(const JobsetId & lhs, const JobsetName & rhs)
{
    return ! (lhs == rhs);
}

enum class EvaluationStyle
{
    SCHEDULE = 1,
    ONESHOT = 2,
    ONE_AT_A_TIME = 3,
};

struct Jobset
{
    JobsetId name;
    std::optional<EvaluationStyle> evaluation_style;
    time_t lastCheckedTime, triggerTime;
    time_t checkInterval;
    Pid pid;
};

using Jobsets = std::map<JobsetId, Jobset>;

struct State
{
    size_t runningEvals = 0;
    Jobsets jobsets;
};

struct EvaluatorState
{
    Sync<State> state_;

    std::condition_variable childStarted;
    std::condition_variable maybeDoWork;

    std::optional<JobsetName> evalOne;

    const time_t notTriggered = std::numeric_limits<time_t>::max();
};

static void reaper(EvaluatorState & evalState, nix::Pool<Connection> & dbPool)
{
    AsyncIoRoot aio;

    while (true) {
        {
            auto state(evalState.state_.lock());
            while (!state->runningEvals)
                state.wait(evalState.childStarted);
        }

        int status;
        pid_t pid = waitpid(-1, &status, 0);
        if (pid == -1) {
            if (errno == EINTR) continue;
            throw SysError("waiting for children");
        }

        {
            auto state(evalState.state_.lock());
            assert(state->runningEvals);
            state->runningEvals--;

            // FIXME: should use a map.
            for (auto & i : state->jobsets) {
                auto & jobset(i.second);

                if (jobset.pid.get() == pid) {
                    printInfo("evaluation of jobset ‘%s’ %s",
                        jobset.name.display(), statusToString(status));

                    auto now = time(nullptr);

                    jobset.triggerTime = evalState.notTriggered;
                    jobset.lastCheckedTime = now;

                    try {

                        auto conn(aio.blockOn(dbPool.get()));
                        pqxx::work txn(*conn);

                        /* Clear the trigger time to prevent this
                           jobset from getting stuck in an endless
                           failing eval loop. */
                        txn.exec
                            ("update Jobsets set triggerTime = null where id = $1 and startTime is not null and triggerTime <= startTime",
                             pqxx::params{jobset.name.id}).no_rows();

                        /* Clear the start time. */
                        txn.exec
                            ("update Jobsets set startTime = null where id = $1",
                             pqxx::params{jobset.name.id}).no_rows();

                        if (!WIFEXITED(status) || WEXITSTATUS(status) > 1) {
                            txn.exec
                                ("update Jobsets set errorMsg = $1, lastCheckedTime = $2, errorTime = $2, fetchErrorMsg = null where id = $3",
                                 pqxx::params{
                                     fmt("evaluation %s", statusToString(status)),
                                     now,
                                     jobset.name.id
                                 }).no_rows();
                        }

                        txn.commit();

                    } catch (std::exception & e) {
                        printError("exception setting jobset error: %s", e.what());
                    }

                    jobset.pid.release();
                    evalState.maybeDoWork.notify_one();

                    if (evalState.evalOne) std::_Exit(0);

                    break;
                }
            }
        }
    }
}

struct Monitor
{
    nix::Pool<Connection> & dbPool;
    EvaluatorState & evalState;
    nix::AsyncIoRoot & aio;

    Monitor(nix::Pool<Connection> & dbPool, EvaluatorState & state, nix::AsyncIoRoot & aio)
        : dbPool(dbPool)
        , evalState(state)
        , aio(aio)
    {}

    /* A thread that listens to PostgreSQL notifications about jobset
       changes, updates the jobsets map, and signals the main thread
       to start evaluations. */
    void databaseMonitor()
    {
        while (true) {
            try {
                auto conn(aio.blockOn(dbPool.get()));

                receiver jobsetsAdded(*conn, "jobsets_added");
                receiver jobsetsDeleted(*conn, "jobsets_deleted");
                receiver jobsetsChanged(*conn, "jobset_scheduling_changed");

                while (true) {
                    /* Note: we read/notify before
                       await_notification() to ensure we don't miss a
                       state change. */
                    readJobsets();
                    evalState.maybeDoWork.notify_one();
                    conn->await_notification();
                    printInfo("received jobset event");
                }

            } catch (pqxx::broken_connection & e) {
                printError("Database connection broken: %s", e.what());
                std::_Exit(1);
            } catch (std::exception & e) {
                printError("exception in database monitor thread: %s", e.what());
                sleep(30);
            }
        }
    }

    void readJobsets()
    {
        auto conn(aio.blockOn(dbPool.get()));

        pqxx::work txn(*conn);

        auto res = txn.exec
            ("select j.id as id, project, j.name, lastCheckedTime, triggerTime, checkInterval, j.enabled as jobset_enabled "
             "from Jobsets j "
             "join Projects p on j.project = p.name "
             "where j.enabled != 0 and p.enabled != 0");


        auto state(evalState.state_.lock());

        std::set<JobsetId> seen;

        for (auto const & row : res) {
            auto name = JobsetId{row["project"].as<std::string>(), row["name"].as<std::string>(), row["id"].as<int>()};

            if (evalState.evalOne && name != *evalState.evalOne) continue;

            auto res = state->jobsets.try_emplace(name, Jobset{.name=name});

            auto & jobset = res.first->second;
            jobset.lastCheckedTime = row["lastCheckedTime"].as<time_t>(0);
            jobset.triggerTime = row["triggerTime"].as<time_t>(evalState.notTriggered);
            jobset.checkInterval = row["checkInterval"].as<time_t>();

            int eval_style = row["jobset_enabled"].as<int>(0);
            switch (eval_style) {
                case 1:
                    jobset.evaluation_style = EvaluationStyle::SCHEDULE;
                    break;
                case 2:
                    jobset.evaluation_style = EvaluationStyle::ONESHOT;
                    break;
                case 3:
                    jobset.evaluation_style = EvaluationStyle::ONE_AT_A_TIME;
                    break;
                default:
                    // Disabled or unknown. Leave as nullopt.
                    break;
            }

            seen.insert(name);
        }

        if (evalState.evalOne && seen.empty()) {
            printError("the specified jobset does not exist or is disabled");
            std::_Exit(1);
        }

        for (auto i = state->jobsets.begin(); i != state->jobsets.end(); )
            if (seen.count(i->first))
                ++i;
            else {
                printInfo("forgetting jobset ‘%s’", i->first.display());
                i = state->jobsets.erase(i);
            }
    }
};

struct Evaluator
{
    std::unique_ptr<HydraConfig> config;
    nix::Pool<Connection> & dbPool;
    EvaluatorState & evalState;
    nix::AsyncIoRoot & aio;
    const size_t maxEvals;
    const time_t notTriggered = std::numeric_limits<time_t>::max();

    Evaluator(nix::Pool<Connection> & dbPool, EvaluatorState & evalState, nix::AsyncIoRoot & aio)
        : config(std::make_unique<HydraConfig>())
        , dbPool(dbPool)
        , evalState(evalState)
        , aio(aio)
        , maxEvals(std::max((size_t) 1, (size_t) config->getIntOption("max_concurrent_evals", 4)))
    { }


    void startEval(State & state, Jobset & jobset)
    {
        time_t now = time(nullptr);

        printInfo("starting evaluation of jobset ‘%s’ (last checked %d s ago)",
            jobset.name.display(),
            now - jobset.lastCheckedTime);

        {
            auto conn(aio.blockOn(dbPool.get()));
            pqxx::work txn(*conn);
            txn.exec
                ("update Jobsets set startTime = $1 where id = $2",
                 pqxx::params{now, jobset.name.id}).no_rows();
            txn.commit();
        }

        assert(!jobset.pid);

        jobset.pid = startProcess([&]() {
            Strings args = { "hydra-eval-jobset", jobset.name.project, jobset.name.jobset };
            execvp(args.front().c_str(), stringsToCharPtrs(args).data());
            throw SysError("executing ‘%1%’", args.front());
        });

        state.runningEvals++;

        evalState.childStarted.notify_one();
    }

    bool shouldEvaluate(Jobset & jobset)
    {
        if (jobset.pid) {
            // Already running.
            debug("shouldEvaluate %s? no: already running",
                  jobset.name.display());
            return false;
        }

        if (jobset.triggerTime != std::numeric_limits<time_t>::max()) {
            // An evaluation of this Jobset is requested
            debug("shouldEvaluate %s? yes: requested",
                  jobset.name.display());
            return true;
        }

        if (jobset.checkInterval <= 0) {
            // Automatic scheduling is disabled. We allow requested
            // evaluations, but never schedule start one.
            debug("shouldEvaluate %s? no: checkInterval <= 0",
                  jobset.name.display());
            return false;
        }

        if (jobset.lastCheckedTime + jobset.checkInterval <= time(nullptr)) {
            // Time to schedule a fresh evaluation. If the jobset
            // is a ONE_AT_A_TIME jobset, ensure the previous jobset
            // has no remaining, unfinished work.

            auto conn(aio.blockOn(dbPool.get()));

            pqxx::work txn(*conn);

            if (jobset.evaluation_style == EvaluationStyle::ONE_AT_A_TIME) {
                auto evaluation_res = txn.exec
                    ("select id from JobsetEvals "
                     "where jobset_id = $1 "
                     "order by id desc limit 1"
                    , pqxx::params{jobset.name.id}
                    );

                if (evaluation_res.empty()) {
                    // First evaluation, so allow scheduling.
                    debug("shouldEvaluate(one-at-a-time) %s? yes: no prior eval",
                          jobset.name.display());
                    return true;
                }

                auto evaluation_id = evaluation_res[0][0].as<int>();

                auto unfinished_build_res = txn.exec
                    ("select id from Builds "
                     "join JobsetEvalMembers "
                     "    on (JobsetEvalMembers.build = Builds.id) "
                     "where JobsetEvalMembers.eval = $1 "
                     "  and builds.finished = 0 "
                     " limit 1"
                    ,pqxx::params{evaluation_id}
                    );

                // If the previous evaluation has no unfinished builds
                // schedule!
                if (unfinished_build_res.empty()) {
                    debug("shouldEvaluate(one-at-a-time) %s? yes: no unfinished builds",
                          jobset.name.display());
                    return true;
                } else {
                    debug("shouldEvaluate(one-at-a-time) %s:%s? no: at least one unfinished build",
                           jobset.name.display());
                    return false;
                }


            } else {
                // EvaluationStyle::ONESHOT, EvaluationStyle::SCHEDULED
                debug("shouldEvaluate(oneshot/scheduled) %s? yes: checkInterval elapsed",
                      jobset.name.display());
                return true;
            }
        }

        return false;
    }

    void startEvals(State & state)
    {
        std::vector<Jobsets::iterator> sorted;

        /* Filter out jobsets that have been evaluated recently and have
           not been triggered. */
        for (auto i = state.jobsets.begin(); i != state.jobsets.end(); ++i)
            if (evalState.evalOne ||
                (i->second.evaluation_style && shouldEvaluate(i->second)))
                sorted.push_back(i);

        /* Put jobsets in order of ascending trigger time, last checked
           time, and name. */
        std::ranges::sort(sorted,
            [](const Jobsets::iterator & a, const Jobsets::iterator & b) {
                return
                    a->second.triggerTime != b->second.triggerTime
                    ? a->second.triggerTime < b->second.triggerTime
                    : a->second.lastCheckedTime != b->second.lastCheckedTime
                      ? a->second.lastCheckedTime < b->second.lastCheckedTime
                      : a->first < b->first;
            });

        /* Start jobset evaluations up to the concurrency limit.*/
        for (auto & i : sorted) {
            if (state.runningEvals >= maxEvals) break;
            startEval(state, i->second);
        }
    }

    void loop(AsyncIoRoot & aio)
    {
        auto state(evalState.state_.lock());

        while (true) {

            time_t now = time(nullptr);

            std::chrono::seconds sleepTime = std::chrono::seconds::max();

            if (state->runningEvals < maxEvals) {
                for (auto & i : state->jobsets)
                    if (!i.second.pid &&
                        i.second.checkInterval > 0)
                        sleepTime = std::min(sleepTime, std::chrono::seconds(
                                std::max((time_t) 1, i.second.lastCheckedTime - now + i.second.checkInterval)));
            }

            debug("waiting for %d s", sleepTime.count());
            if (sleepTime == std::chrono::seconds::max())
                state.wait(evalState.maybeDoWork);
            else
                state.wait_for(evalState.maybeDoWork, sleepTime);

            startEvals(*state);
        }
    }

    void unlock()
    {
        auto conn(aio.blockOn(dbPool.get()));
        pqxx::work txn(*conn);
        txn.exec("update Jobsets set startTime = null");
        txn.commit();
    }

    void run(AsyncIoRoot & aio)
    {
        unlock();

        /* Can't be bothered to shut down cleanly. Goodbye! */
        auto callback = createInterruptCallback([&]() { std::_Exit(1); });

        std::thread reaperThread([&]() { reaper(evalState, dbPool); });
        std::thread monitorThread([&]() {
            AsyncIoRoot aio;
            Monitor monitor(dbPool, evalState, aio);
            monitor.databaseMonitor();
        });

        while (true) {
            try {
                loop(aio);
            } catch (pqxx::broken_connection & e) {
                printError("Database connection broken: %s", e.what());
                std::_Exit(1);
            } catch (std::exception & e) {
                printError("exception in main loop: %s", e.what());
                sleep(30);
            }
        }
    }
};

int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();

        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);

        bool unlock = false;

        std::vector<std::string> args;

        nix::AsyncIoRoot aio;
        LegacyArgs(aio, argv[0], [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--unlock")
                unlock = true;
            else if (arg->starts_with("-"))
                return false;
            args.push_back(*arg);
            return true;
        }).parseCmdline(Strings(argv + 1, argv + argc));

        EvaluatorState evalState;
        nix::Pool<Connection> dbPool;
        Evaluator evaluator(dbPool, evalState, aio);

        if (unlock)
            evaluator.unlock();
        else {
            if (!args.empty()) {
                if (args.size() != 2) throw UsageError("Syntax: hydra-evaluator [<project> <jobset>]");
                evalState.evalOne = JobsetName(args[0], args[1]);
            }
            evaluator.run(aio);
        }
    });
}
