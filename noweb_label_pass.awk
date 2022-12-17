# This Awk scripts scans a Markdown source file for code blocks that match the
# Entangled syntax for defining named code blocks, and then inserts a piece
# of raw HTML to label these code blocks.

# This matches "``` {.julia #my-code}"
match($0, /``` *{\.([a-zA-Z0-9\-_]+)[^#}]*#([a-zA-Z0-9\-_]+)[^}]*\}/, a) {
        if (!(a[2] in counts))
            counts[a[1]] = 0

        term = counts[a[2]] == 0 ? "≣" : "⊞"

        print "<div class=\"noweb-label\">⪡" a[2] "⪢" term "</div>"
        # print "```" a[1]
        counts[a[2]] = counts[a[2]] + 1
}

# This matches "``` {.julia file=src/my-file.jl}"
match($0, /``` *{\.([a-zA-Z0-9\-_]+)[^}]*file=([a-zA-Z0-9\-_\.\/\\]+)[^}]*}/, a) {
        print "<div class=\"noweb-label\">file:<i>" a[2] "</i></div>"
        # print "```" a[1]
}

match($0, /``` *{.([a-zA-Z0-9\-_]+).*/, a) {
        print "```" a[1]
}

# Print everything else too
!match($0, /``` *{.*/) {
    print
}
