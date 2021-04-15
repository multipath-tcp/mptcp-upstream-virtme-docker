#!/bin/bash
cd "$(dirname "$(realpath -P "${0}")")"
docker build -t virtme -f Dockerfile .
