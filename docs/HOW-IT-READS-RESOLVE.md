# How Rushes reads Resolve

A project of the local disk database is a SQLite file. The clips on a timeline have their path in plain text. The
media pool has it in a small protobuf message. Rushes copies the file first, reads the copy, and matches by card number
and path inside the card instead of by the whole path. If you use a PostgreSQL database, the projects cannot be read
this way. Clips you used since the last time you saved the project show as unused until you save it (Cmd S).

