#pragma once

#include "lix/libstore/fs-accessor.hh"
#include "lix/libutil/hash.hh"
#include "lix/libutil/serialise.hh"
#include "lix/libutil/types.hh"

struct NarMemberData
{
    nix::FSAccessor::Type type;
    std::optional<uint64_t> fileSize;
    std::optional<std::string> contents;
    std::optional<nix::Hash> sha256;
};

using NarMemberDatas = std::map<nix::Path, NarMemberData>;

/* Read a NAR from a source and get to some info about every file
   inside the NAR. */
kj::Promise<nix::Result<void>> extractNarData(
    nix::AsyncInputStream & source,
    const nix::Path & prefix,
    NarMemberDatas & members);
