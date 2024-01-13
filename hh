#!/bin/sh

if [[ -z $1 ]]; then echo "Please, provide hostname to edit in hiera-backend"; exit 1; fi
full_path=$(find ~/devops/hiera-backend -name "${1}*" | head -n 1)
git log ${full_path#*hiera-backend/}
