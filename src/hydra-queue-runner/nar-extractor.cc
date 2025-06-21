#include "nar-extractor.hh"

#include "lix/libutil/archive.hh"

#include <lix/libutil/box_ptr.hh>
#include <lix/libutil/serialise.hh>
#include <lix/libutil/types.hh>
#include <unordered_set>
#include <utility>

#include <filesystem>

using namespace nix;

static std::filesystem::path stripTrailingSlash(std::filesystem::path && p)
{
    auto new_path = p.lexically_normal();
    if (new_path.filename().empty()) {
        return new_path.parent_path();
    }
    return new_path;
}

kj::Promise<Result<void>> extractNarData(
    AsyncInputStream & source,
    const Path & prefix,
    NarMemberDatas & members)
try {
    static const std::unordered_set<Path> filesToKeep{
        "/nix-support/hydra-build-products",
        "/nix-support/hydra-release-name",
        "/nix-support/hydra-metrics",
    };

    struct HydraNARVisitor : NARParseVisitor
    {
        private:
            std::filesystem::path prefix;
            std::filesystem::path pathSuffix;
            NarMemberDatas & members;

        public:
        explicit HydraNARVisitor(NarMemberDatas & members, Path prefix, Path pathSuffix = "") : prefix(std::move(prefix)), pathSuffix(std::move(pathSuffix)), members(members) { }

        box_ptr<NARParseVisitor> createDirectory(const std::string & name) override
        {
            auto pref = stripTrailingSlash(prefix / pathSuffix / name);
            members.insert_or_assign(
                    pref, NarMemberData{.type = FSAccessor::Type::tDirectory});

            return make_box_ptr<HydraNARVisitor>(members, prefix, pathSuffix / name);
        }


        box_ptr<FileHandle> createRegularFile(const std::string & name, uint64_t size, bool _executable) override
        {
            struct HashingHandle : FileHandle
            {
            private:
                HashSink hasher;
                NarMemberData & narData;
                uint64_t expectedSize;


            public:
                HashingHandle(NarMemberData & narData, uint64_t expectedSize) : hasher(HashType::SHA256), narData(narData), expectedSize(expectedSize) { }

                void receiveContents(std::string_view data) override
                {
                    hasher(data);
                    *narData.fileSize += data.size();
                    if (narData.contents)
                        narData.contents->append(data);

                    assert(narData.fileSize <= expectedSize);
                }

                void close() override
                {
                    assert(narData.fileSize == expectedSize);
                    auto [hash, len] = hasher.finish();
                    assert(narData.fileSize == len);
                    narData.sha256 = hash;
                }
            };

            auto fullPath = stripTrailingSlash(prefix / pathSuffix / name);
            auto memberData = &members.insert_or_assign(fullPath.lexically_normal(), NarMemberData{
                .type = FSAccessor::Type::tRegular,
                .fileSize = 0,
                .contents = filesToKeep.count("/" / pathSuffix / name) ?
                std::optional("") : std::nullopt
            }).first->second;

            auto x = members[fullPath];
            return make_box_ptr<HashingHandle>(*memberData, size);
        }


        void createSymlink(const std::string & name, const std::string & target) override
        {
            members.insert_or_assign(
                    stripTrailingSlash(prefix / pathSuffix / name),
                    NarMemberData{.type = FSAccessor::Type::tSymlink});
        }
    };

    auto visitor = HydraNARVisitor(members, prefix);

    LIX_TRY_AWAIT(parseDump(visitor, source));

    co_return result::success();
} catch (...) {
    co_return result::current_exception();
}
