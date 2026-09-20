#!/bin/bash

file="$1"

case "$file" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.bmp)
        chafa --format symbols --size "${2:-80}x${3:-30}" "$file"
        ;;

    *.md|*.txt|*.conf|*.cfg|*.ini|*.sh|*.bash|*.zsh|*.py|*.lua|*.vim|*.json|*.yaml|*.yml|*.xml|*.html|*.css)
        bat --style=plain --paging=never --color=always "$file"
        ;;

    *.pdf)
        pdftotext -layout "$file" -
        ;;

    *)
        file "$file"
        echo
        du -sh "$file" 2>/dev/null | awk '{print "Size: " $1}'
        ;;
esac
