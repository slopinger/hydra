#pragma once
//@file

#include "lix/libutil/serialise.hh"

/**
 * A source that reads data from a file descriptor
 * and maintain a counter `read` of how many bytes were read.
 */
struct CountingFdSource : nix::FdSource {
    size_t read = 0;


    CountingFdSource() = default;
    CountingFdSource(int fd) : FdSource(fd) { }

protected:
    size_t readUnbuffered(char * data, size_t len) override {
        size_t actualRead = nix::FdSource::readUnbuffered(data, len);
        read += actualRead;
        return actualRead;
    }
};
