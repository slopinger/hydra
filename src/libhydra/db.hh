#pragma once

#include <pqxx/pqxx>

#include "lix/libutil/environment-variables.hh"
#include "lix/libutil/strings.hh"


struct Connection : pqxx::connection
{
    Connection() : pqxx::connection(getFlags()) { };

    std::string getFlags()
    {
        using namespace nix;
        auto s = getEnv("HYDRA_DBI").value_or("dbi:Pg:dbname=hydra;");

        std::string lower_prefix = "dbi:Pg:";
        std::string upper_prefix = "DBI:Pg:";

        if (s.starts_with(lower_prefix) || s.starts_with(upper_prefix)) {
            return concatStringsSep(" ", tokenizeString<Strings>(std::string(s, lower_prefix.size()), ";"));
        }

        throw Error("$HYDRA_DBI does not denote a PostgreSQL database");
    }
};


class receiver
{
    std::optional<std::string> status;

public:

    receiver(pqxx::connection_base & c, const std::string & channel)
    {
        c.listen(channel, [&](pqxx::notification n) -> void {
            status = n.payload;
        });
    }

    std::optional<std::string> get() {
        auto s = status;
        status = std::nullopt;
        return s;
    }
};
