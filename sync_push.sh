#! /bin/bash

git checkout latest
git push

git checkout net
git merge --signoff --no-edit latest
git push

git checkout latest
