#!/bin/bash

SKOPEO_BINARY=${SKOPEO_BINARY:-$(dirname ${BASH_SOURCE})/../skopeo}

# Default timeout for a skopeo command.
SKOPEO_TIMEOUT=${SKOPEO_TIMEOUT:-300}

###############################################################################
# BEGIN setup/teardown

# Provide common setup and teardown functions, but do not name them such!
# That way individual tests can override with their own setup/teardown,
# while retaining the ability to include these if they so desire.

function standard_setup() {
    # Argh. Although BATS provides $BATS_TMPDIR, it's just /tmp!
    # That's bloody worthless. Let's make our own, in which subtests
    # can write whatever they like and trust that it'll be deleted
    # on cleanup.
    TESTDIR=$(mktemp -d --tmpdir=${BATS_TMPDIR:-/tmp} skopeo_bats.XXXXXX)
}

function standard_teardown() {
    if [[ -n $TESTDIR ]]; then
        rm -rf $TESTDIR
    fi
}

# Individual .bats files may override or extend these
function setup() {
    standard_setup
}

function teardown() {
    standard_teardown
}

# END   setup/teardown
###############################################################################
# BEGIN standard helpers for running skopeo and testing results

#################
#  run_skopeo  #  Invoke skopeo, with timeout, using BATS 'run'
#################
#
# This is the preferred mechanism for invoking skopeo:
#
#  * we use 'timeout' to abort (with a diagnostic) if something
#    takes too long; this is preferable to a CI hang.
#  * we log the command run and its output. This doesn't normally
#    appear in BATS output, but it will if there's an error.
#  * we check exit status. Since the normal desired code is 0,
#    that's the default; but the first argument can override:
#
#     run_skopeo 125  nonexistent-subcommand
#     run_skopeo '?'  some-other-command       # let our caller check status
#
# Since we use the BATS 'run' mechanism, $output and $status will be
# defined for our caller.
#
function run_skopeo() {
    # Number as first argument = expected exit code; default 0
    expected_rc=0
    case "$1" in
        [0-9])           expected_rc=$1; shift;;
        [1-9][0-9])      expected_rc=$1; shift;;
        [12][0-9][0-9])  expected_rc=$1; shift;;
        '?')             expected_rc=  ; shift;;  # ignore exit code
    esac

    # Remember command args, for possible use in later diagnostic messages
    MOST_RECENT_SKOPEO_COMMAND="skopeo $*"

    # stdout is only emitted upon error; this echo is to help a debugger
    echo "\$ $SKOPEO_BINARY $*"
    run timeout --foreground --kill=10 $SKOPEO_TIMEOUT ${SKOPEO_BINARY} "$@"
    # without "quotes", multiple lines are glommed together into one
    if [ -n "$output" ]; then
        echo "$output"
    fi
    if [ "$status" -ne 0 ]; then
        echo -n "[ rc=$status ";
        if [ -n "$expected_rc" ]; then
            if [ "$status" -eq "$expected_rc" ]; then
                echo -n "(expected) ";
            else
                echo -n "(** EXPECTED $expected_rc **) ";
            fi
        fi
        echo "]"
    fi

    if [ "$status" -eq 124 -o "$status" -eq 137 ]; then
        # FIXME: 'timeout -v' requires coreutils-8.29; travis seems to have
        #        an older version. If/when travis updates, please add -v
        #        to the 'timeout' command above, and un-comment this out:
        # if expr "$output" : ".*timeout: sending" >/dev/null; then
        echo "*** TIMED OUT ***"
        false
    fi

    if [ -n "$expected_rc" ]; then
        if [ "$status" -ne "$expected_rc" ]; then
            die "exit code is $status; expected $expected_rc"
        fi
    fi
}

#########
#  die  #  Abort with helpful message
#########
function die() {
    echo "#/vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv"  >&2
    echo "#| FAIL: $*"                                           >&2
    echo "#\\^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^" >&2
    false
}

###################
#  expect_output  #  Compare actual vs expected string; fail if mismatch
###################
#
# Compares $output against the given string argument. Optional second
# argument is descriptive text to show as the error message (default:
# the command most recently run by 'run_skopeo'). This text can be
# useful to isolate a failure when there are multiple identical
# run_skopeo invocations, and the difference is solely in the
# config or setup; see, e.g., run.bats:run-cmd().
#
# By default we run an exact string comparison; use --substring to
# look for the given string anywhere in $output.
#
# By default we look in "$output", which is set in run_skopeo().
# To override, use --from="some-other-string" (e.g. "${lines[0]}")
#
# Examples:
#
#   expect_output "this is exactly what we expect"
#   expect_output "foo=bar"  "description of this particular test"
#   expect_output --from="${lines[0]}"  "expected first line"
#
function expect_output() {
    # By default we examine $output, the result of run_skopeo
    local actual="$output"
    local check_substring=

    # option processing: recognize --from="...", --substring
    local opt
    for opt; do
        local value=$(expr "$opt" : '[^=]*=\(.*\)')
        case "$opt" in
            --from=*)       actual="$value";   shift;;
            --substring)    check_substring=1; shift;;
            --)             shift; break;;
            -*)             die "Invalid option '$opt'" ;;
            *)              break;;
        esac
    done

    local expect="$1"
    local testname="${2:-${MOST_RECENT_SKOPEO_COMMAND:-[no test name given]}}"

    if [ -z "$expect" ]; then
        if [ -z "$actual" ]; then
            return
        fi
        expect='[no output]'
    elif [ "$actual" = "$expect" ]; then
	return
    elif [ -n "$check_substring" ]; then
        if [[ "$actual" =~ $expect ]]; then
            return
        fi
    fi

    # This is a multi-line message, which may in turn contain multi-line
    # output, so let's format it ourself, readably
    local -a actual_split
    readarray -t actual_split <<<"$actual"
    printf "#/vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\n" >&2
    printf "#|     FAIL: $testname\n"                          >&2
    printf "#| expected: '%s'\n" "$expect"                     >&2
    printf "#|   actual: '%s'\n" "${actual_split[0]}"          >&2
    local line
    for line in "${actual_split[@]:1}"; do
        printf "#|         > '%s'\n" "$line"                   >&2
    done
    printf "#\\^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n" >&2
    false
}

#######################
#  expect_line_count  #  Check the expected number of output lines
#######################
#
# ...from the most recent run_skopeo command
#
function expect_line_count() {
    local expect="$1"
    local testname="${2:-${MOST_RECENT_SKOPEO_COMMAND:-[no test name given]}}"

    local actual="${#lines[@]}"
    if [ "$actual" -eq "$expect" ]; then
        return
    fi

    printf "#/vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\n"          >&2
    printf "#| FAIL: $testname\n"                                       >&2
    printf "#| Expected %d lines of output, got %d\n" $expect $actual   >&2
    printf "#| Output was:\n"                                           >&2
    local line
    for line in "${lines[@]}"; do
        printf "#| >%s\n" "$line"                                       >&2
    done
    printf "#\\^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n"         >&2
    false
}

# END   standard helpers for running skopeo and testing results
###############################################################################
# BEGIN helpers for starting/stopping registries

####################
#  start_registry  #  Run a local registry container
####################
#
# Usage:  start_registry [OPTIONS] NAME
#
#   OPTIONS
#       --port=NNNN         Port to listen on (default: 5000)
#       --testuser=XXX      Require authentication; this is the username
#       --testpassword=XXX  ...and the password (these two go together)
#       --with-cert         Create a cert for running with TLS (not working)
#
#   NAME is the container name to assign.
#
start_registry() {
    local port=5000
    local testuser=
    local testpassword=
    local create_cert=

    # option processing: recognize options for running the registry
    # in different modes.
    local opt
    for opt; do
        local value=$(expr "$opt" : '[^=]*=\(.*\)')
        case "$opt" in
            --port=*)           port="$value";          shift;;
            --testuser=*)       testuser="$value";      shift;;
            --testpassword=*)   testpassword="$value";  shift;;
            --with-cert)        create_cert=1;          shift;;
            -*)                 die "Invalid option '$opt'" ;;
            *)                  break;;
        esac
    done

    local name=${1?start_registry() invoked without a NAME}

    # Temp directory must be defined and must exist
    [[ -n $TESTDIR && -d $TESTDIR ]]

    AUTHDIR=$TESTDIR/auth
    mkdir -p $AUTHDIR

    local -a reg_args=(-v $AUTHDIR:/auth:Z -p $port:5000)

    # cgroup option necessary under podman-in-podman (CI tests),
    # and doesn't seem to do any harm otherwise.
    PODMAN="podman --cgroup-manager=cgroupfs"

    # Called with --testuser? Create an htpasswd file
    if [[ -n $testuser ]]; then
        if [[ -z $testpassword ]]; then
            die "start_registry() invoked with testuser but no testpassword"
        fi

        if ! egrep -q "^$testuser:" $AUTHDIR/htpasswd; then
            $PODMAN run --rm --entrypoint htpasswd registry:2 \
                   -Bbn $testuser $testpassword >> $AUTHDIR/htpasswd
        fi

        reg_args+=(
            -e REGISTRY_AUTH=htpasswd
            -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
            -e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm"
        )
    fi

    # Called with --with-cert? Create certificates.
    if [[ -n $create_cert ]]; then
        CERT=$AUTHDIR/domain.crt
        if [ ! -e $CERT ]; then
            openssl req -newkey rsa:4096 -nodes -sha256 \
                    -keyout $AUTHDIR/domain.key -x509 -days 2 \
                    -out $CERT \
                    -subj "/C=US/ST=Foo/L=Bar/O=Red Hat, Inc./CN=localhost"
        fi

        reg_args+=(
            -e REGISTRY_HTTP_TLS_CERTIFICATE=/auth/domain.crt
            -e REGISTRY_HTTP_TLS_KEY=/auth/domain.key
        )

        # Copy .crt file to a directory *without* the .key one, so we can
        # test the client. (If client sees a matching .key file, it fails)
        # Thanks to Miloslav Trmac for this hint.
        mkdir -p $TESTDIR/client-auth
        cp $CERT $TESTDIR/client-auth/
    fi

    $PODMAN run -d --name $name "${reg_args[@]}" registry:2
}

# END   helpers for starting/stopping registries
###############################################################################
# BEGIN miscellaneous tools

###################
#  random_string  #  Returns a pseudorandom human-readable string
###################
#
# Numeric argument, if present, is desired length of string
#
function random_string() {
    local length=${1:-10}

    head /dev/urandom | tr -dc a-zA-Z0-9 | head -c$length
}

# END   miscellaneous tools
###############################################################################
