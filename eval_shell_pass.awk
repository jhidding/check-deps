match($0, /``` *{\.bash \.eval/) {
        print "```bash"
        active = 1
}

!/(``` *{.*\.eval)|(^```$)/ {
        print
        if (active) {
                body = body $0 "\n"
        }
}

match($0, /^```$/) {
        if (active) {
                print $0
                print ""

                out = ""
                while(body | getline l) {
                        out = out l "\n"
                }

                print "*output:*"
                print "```"
                print out "```"

                body = ""
                out = ""
                active = !active
        } else {
                print
        }
}

