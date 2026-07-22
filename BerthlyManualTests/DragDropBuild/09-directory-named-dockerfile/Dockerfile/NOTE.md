This directory is named `Dockerfile` on purpose — it's not a file.

Dragging the `Dockerfile` entry in the parent folder (`09-directory-named-dockerfile/`)
onto Berthly should be **rejected**: the name passes the filename check, but
the resolver's regular-file check then fails, since this is a directory.
