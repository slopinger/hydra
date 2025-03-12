#include "nar-extractor.hh"

#include "lix/libutil/archive.hh"

#include <lix/libutil/box_ptr.hh>
#include <lix/libutil/serialise.hh>
#include <lix/libutil/types.hh>
#include <unordered_set>
#include <utility>

using namespace nix;

static Generator<Bytes> readHydraData(
    NarMemberData &narData,
    Generator<Bytes> contents,
    uint64_t size)
{
    HashSink hashSink(HashType::SHA256);
    while (auto block = contents.next()) {
        std::string_view data = {block->data(), block->size()};

        *narData.fileSize += block->size();
        hashSink(data);
        if (narData.contents) {
            narData.contents->append(data);
        }
        assert(narData.fileSize <= size);
        if (narData.fileSize == size) {
            auto [hash, len] = hashSink.finish();
            assert(narData.fileSize == len);
            narData.sha256 = hash;
        }

        co_yield *block;
    }
}

static Generator<nar::Entry> discoverHydraDataInNAR(
    NarMemberDatas &members,
    const Path &prefix,
    const Path pathSuffix,
    nar::Entry root)
{
    static const std::unordered_set<Path> filesToKeep{
        "/nix-support/hydra-build-products",
        "/nix-support/hydra-release-name",
        "/nix-support/hydra-metrics",
    };

    nix::overloaded handlers {
        [&](nar::File f) -> nar::Entry {
            return nar::File{
                f.executable,
                f.size,
                [](
                    nar::File f,
                    NarMemberDatas &members,
                    const Path &pathSuffix,
                    const Path &prefix
                ) -> Generator<Bytes> {
                    auto pref = prefix + pathSuffix;
                    auto memberData = NarMemberData{
                        .type = FSAccessor::Type::tRegular,
                        .fileSize = 0,
                        .contents = filesToKeep.count(pathSuffix)
                            ? std::optional("")
                            : std::nullopt,
                    };
                    co_yield readHydraData(memberData, std::move(f.contents), f.size);
                    members.insert_or_assign(pref, memberData);
                }(std::move(f), members, pathSuffix, prefix),
            };
        },
        [&](nar::Symlink sl) -> nar::Entry {
            members.insert_or_assign(
                prefix + pathSuffix,
                NarMemberData{.type = FSAccessor::Type::tSymlink});
            return sl;
        },
        [&](nar::Directory d) -> nar::Entry {
            auto pref = prefix + pathSuffix;
            members.insert_or_assign(
                pref, NarMemberData{.type = FSAccessor::Type::tDirectory});

            return nar::Directory{
                ([](
                    NarMemberDatas &members,
                    nar::Directory d,
                    const Path &prefix,
                    const Path &pathSuffix
                ) -> Generator<std::pair<const std::string&, nar::Entry>> {
                    while (auto e = d.contents.next()) {
                        auto iter = discoverHydraDataInNAR(
                            members,
                            prefix,
                            pathSuffix + "/" + e->first,
                            std::move(e->second)
                        );
                        co_yield std::pair{
                            std::cref(e->first),
                            *iter.next(),
                        };
                        assert(!iter.next().has_value());
                    }
                }(members, std::move(d), prefix, pathSuffix))};
        }
    };

    co_yield std::visit(handlers, std::move(root));
}

void extractNarData(
    box_ptr<Source> & source,
    const Path & prefix,
    NarMemberDatas & members)
{
    auto parser = extractNarDataFilter(*source, prefix, members);
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
        auto items = nar::parse(source);
        auto inner = discoverHydraDataInNAR(
            members,
            prefix,
            "",
            std::move(*items.next())
        );
        co_yield nar::dump(*inner.next());
        assert(!items.next().has_value());
        assert(!inner.next().has_value());
    }(source, prefix, members);
}
