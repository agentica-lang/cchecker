#!/bin/sh
# A clang-tidy that prints one plain finding and one in colour, which cchecker cannot read.
printf 'clean.c:1:1: warning: plain [bugprone-integer-division]\n'
printf '\033[1mclean.c:2:1: \033[0m\033[0;1;35mwarning: \033[0m\033[1mcoloured [bugprone-integer-division]\033[0m\n'
