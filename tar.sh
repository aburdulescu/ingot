#!/bin/sh

set -e

tar \
    --sort=name \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mtime='2001-01-01' \
    --pax-option='exthdr.name=%d/PaxHeaders/%f,exthdr.time=atime,delete=atime,delete=ctime' \
    -cf opt.tar ~/opt
