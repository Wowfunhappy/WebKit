# Parse Google Test's --gtest_list_tests output. Typed suites and value tests
# have slash suffixes; their trailing TypeParam/GetParam comments are not names.
/^[^[:space:]]/ {
    suite = ""
    if ($1 ~ /^[A-Za-z_][A-Za-z0-9_\/]*\.$/ && $1 !~ /(^|\/)DISABLED_/)
        suite = $1
    next
}
/^  / && suite != "" {
    if ($1 ~ /^[A-Za-z_][A-Za-z0-9_\/]*$/ && $1 !~ /(^|\/)DISABLED_/)
        print suite $1
}
