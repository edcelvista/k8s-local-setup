#!/bin/bash
multipass list | grep edcelvistacom-local | awk '{print $1}' | while read v; do multipass stop $v; done
multipass list