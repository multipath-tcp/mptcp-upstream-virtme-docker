#! /bin/bash -e

STASHED=0

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "There are modified files that might be wiped during the update. Stashing them."
	git stash
	STASHED=1
fi

git switch latest
git push

git switch net
git merge --signoff --no-edit latest
git push

git switch latest

if [ ${STASHED} -eq 1 ]; then
	echo "Unstashing modifications from before the update."
	git stash pop
fi
