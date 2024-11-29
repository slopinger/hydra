#include "nar-extractor.hh"

#include "lix/libutil/archive.hh"

#include <unordered_set>
#include <utility>

using namespace nix;

struct Extractor : NARParseVisitor
{
    class MyFileHandle : public FileHandle
    {
        NarMemberData & memberData;
        uint64_t expectedSize;
        std::unique_ptr<HashSink> hashSink;

        public:
            MyFileHandle(NarMemberData & memberData, uint64_t size) : memberData(memberData), expectedSize(size)
            {
                hashSink = std::make_unique<HashSink>(HashType::SHA256);
            }

            void receiveContents(std::string_view data) override
            {
                *memberData.fileSize += data.size();
                (*hashSink)(data);
                if (memberData.contents) {
                    memberData.contents->append(data);
                }
                assert(memberData.fileSize <= expectedSize);
                if (memberData.fileSize == expectedSize) {
                    auto [hash, len] = hashSink->finish();
                    assert(memberData.fileSize == len);
                    memberData.sha256 = hash;
                    hashSink.reset();
                }
            }
    };

    std::unordered_set<Path> filesToKeep {
        "/nix-support/hydra-build-products",
        "/nix-support/hydra-release-name",
        "/nix-support/hydra-metrics",
    };

    NarMemberDatas & members;
    Path prefix;

    Extractor(NarMemberDatas & members, Path  prefix)
        : members(members), prefix(std::move(prefix))
    { }

    void createDirectory(const Path & path) override
    {
        members.insert_or_assign(prefix + path, NarMemberData { .type = FSAccessor::Type::tDirectory });
    }

    std::unique_ptr<FileHandle> createRegularFile(const Path & path, uint64_t size, bool executable) override
    {
        auto memberData = &members.insert_or_assign(prefix + path, NarMemberData {
            .type = FSAccessor::Type::tRegular,
            .fileSize = 0,
            .contents = filesToKeep.count(path) ? std::optional("") : std::nullopt,
        }).first->second;

        return std::make_unique<MyFileHandle>(*memberData, size);
    }

    void createSymlink(const Path & path, const std::string & target) override
    {
        members.insert_or_assign(prefix + path, NarMemberData { .type = FSAccessor::Type::tSymlink });
    }
};


void extractNarData(
    Source & source,
    const Path & prefix,
    NarMemberDatas & members)
{
    auto parser = extractNarDataFilter(source, prefix, members);
    while (parser.next()) {
        // ignore raw data
    }
}

nix::WireFormatGenerator extractNarDataFilter(
    Source & source,
    const Path & prefix,
    NarMemberDatas & members)
{
    return [](Source & source, const Path & prefix, NarMemberDatas & members) -> WireFormatGenerator {
        Extractor extractor(members, prefix);
        co_yield parseAndCopyDump(extractor, source);
    }(source, prefix, members);
}
