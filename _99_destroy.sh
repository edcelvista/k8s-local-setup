#!/bin/bash
multipass list | grep edcelvistacom-local | awk '{print $1}' | while read v; do multipass delete $v; done
multipass purge
rm -rf kubespray ; rm -rf .cfg