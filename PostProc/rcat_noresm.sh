#!/bin/bash

### Tool to concatenate and compress NorESM day-files to month- or year-files
##
## Currently able to handle output files from 'atm', 'ice', 'lnd',
##    'ocn', and 'rof' components.

# Modified by Steve Goldhaber Met, 2023
# Original version from Tyge Løvset NORCE, last modification 2022
# use on e.g.:
# /projects/NS9560K/noresm/cases/N1850frc2_f09_tn14_20191113

## Update the script version here to indicate changes
## Use semantic versioning (https://semver.org/).
VERSION="0.0.7"

# Store some pathnames, find tools needed by this script
tool=$(basename $0)
tooldir=$(dirname $(realpath $0))
bindir="/projects/NS9560K/local/bin"
cprnc=${tooldir}/cprnc
xxhsum=${tooldir}/xxhsum
if [ ! -x "${cprnc}" ]; then
    cprnc="${bindir}/cprnc"
fi
if [ ! -x "${cprnc}" ]; then
    echo  "ERROR: No cprnc tool found, should be installed at ${bindir}"
    exit 1
fi
if [ ! -x "${xxhsum}" ]; then
    xxhsum="${bindir}/xxhsum"
fi
if [ ! -x "${xxhsum}" ]; then
    echo  "ERROR: No xxhsum tool found, should be installed at ${bindir}"
    exit 1
fi

## Need to set the locale to be compatible with ncks output
LC_NUMERIC="en_US.UTF-8"

## Variables for optional arguments
COMPARE="None" ## alternatives are 'Spot' or 'Full'
COMPONENTS=()
COMPRESS=2
DELETE=0
DRYRUN="no"
ERRCODE=0
ERRMSG=""
MOVEDIR="/scratch/${USER}/SOURCE_FILES_TO_BE_DELETED"
MOVE=0
MERGETYPE="yearly" # or "monthly" or "mergeall"
declare -i NTHREADS=4
POSITIONAL=()
UNITTESTMODE="no"  # Used for unit testing, skip input checking, error checks, and runs
declare -i VERBOSE=0  # Use --verbose to get more output

## Error codes
ERR_BADARG=02          # Bad command line argument
ERR_NCKS_MDATA=03      # Error extracting file metadata with ncks
ERR_UNSUPPORT_CAL=04   # Unsupported NetCDF calendar type
ERR_UNSUPPORT_TIME=05  # Unsupported NetCDF time units
ERR_BAD_YEAR0=06       # Error extracting year0 from calendar
ERR_BADARG_GT=07       # Bad argument(s) to greater_than
ERR_BADARG_LT=08       # Bad argument(s) to less_than
ERR_BAD_DATESTR=09     # Bad date string from ncks
ERR_BADYEAR=10         # Bad year found in history file
ERR_MULTYEARS=11       # Multiple years found in history file
ERR_MULTMONTHS=12      # Multiple months found in history file
ERR_INTERNAL=13        # Internal error (should not happen)
ERR_MISSING_FILE=14    # File does not exist
ERR_UNSUPPORT_MERGE=15 # Unsupported merge type for file
ERR_BAD_MERGETYPE=16   # Bad (unknown) merge type
ERR_BAD_COMPTYPE=17    # Unknown component type
ERR_BAD_TIME=18        # Error extracting time using ncks
ERR_EXTRACT=19         # Error extracting frame using ncks
ERR_CPRNC=20           # Error running cprnc
ERR_NOCOMPRESS=21      # No files to compress
ERR_NCRCAT=22          # Error running ncrcat
ERR_INTERRUPT=23       # User or system interrupt

## Keep track of failures
declare -A fail_report=()
declare -A job_status=() # Status = created, in compress, compressed, in check, pass, fail
declare -A error_reports=()
## Have a global logfile so that it can be used even in the case of an error exit
declare logfilename
## Use a single timestamp for the logfile and xxhsum files
declare JOBLID

help() {
    echo -e "${tool}, version ${VERSION}\n"
    echo "Tool to compress and convert NorESM day-files to month- or year-files"
    echo "Usage:"
    echo "  ${tool} [OPTIONS] <archive case path> <output path>"
    echo "       --comp              component (default 'ice:cice')"
    echo "   -y  --year  --yearly    merge per year (default)"
    echo "   -m  --month --monthly   merge per month"
    echo "   -a  --merge-all         merge all files"
    echo "   -c  --compress N        compression 1-9 (default 2)"
    echo "   -t  --threads N         parallel run (default 4)"
    echo "       --compare <option>  Options are \"Spot\" (spot check),"
    echo "                           \"Full\", or \"None\" (default)"
    echo "       --verbose           Output and log more information about work in progress"
    echo "       --move              move source files to scratch after merge"
    echo "       --delete            move and delete source files when done"
    echo "       --dryrun            display the files to be merged but do not perform any actions"
    echo "   -v  --version           print the current script version and exit"
    echo "   -h  --help              print this message and exit"
    echo ""
    echo "--compare checks the fidelity of the merged file against a selection (spot) or"
    echo "          every (full) source file. It does this by comparing the frame(s) of a"
    echo "          source file with the corresponding frames of the merged file."
    echo "          Any differences are reported and cause an error exit."
    if [ $# -gt 0 ]; then
        exit $1
    else
        exit
    fi
}

log() {
    ## Echo a message ($@) to the terminal with a copy to the logfile
    echo "${@}" | tee -a ${logfilename}
}

qlog() {
    ## Write a message ($@) to the logfile
    echo "${@}" >> ${logfilename}
}

while [ $# -gt 0 ]; do
  key="$1"
  case $key in
    --comp)
    if [ $# -lt 2 ]; then
        echo "--comp requires a component name argument"
        help
    fi
    COMPONENTS+=($2)
    shift
    ;;
    -a|--merge-all)
    MERGETYPE="mergeall"
    ;;
    -m|--month|--monthly)
    MERGETYPE="monthly"
    ;;
    -y|--year|--yearly)
    MERGETYPE="yearly"
    ;;
    -t|--threads)
    if [ $# -lt 2 ]; then
        echo "${key} requires a number of threads"
        help
    fi
    NTHREADS=$2
    shift
    ;;
    -c|--compress)
    if [ $# -lt 2 ]; then
        echo "${key} requires a compression level (number)"
        help
    fi
    COMPRESS=$2
    shift
    ;;
    --compare)
    if [ $# -lt 2 ]; then
        echo "${key} requires a comparison type"
        help
    fi
    if [ "${2,,}" == "full" ]; then
        COMPARE="Full"
    elif [ "${2,,}" == "spot" ]; then
        COMPARE="Spot"
    elif [ "${2,,}" == "none" ]; then
        COMPARE="None"
    else
        echo "Unknown option to --compare, '${2}'"
    help 1
    fi
    shift
    ;;
    --move)
    MOVE=1
    ;;
    --delete)
    MOVE=1
    DELETE=1
    ;;
    --dryrun)
    DRYRUN="yes"
    ;;
    -h|--help)
    help
    ;;
    --unit-test-mode)
    ## Note, this is not documented (not a user-level switch)
    UNITTESTMODE="yes"
    ;;
    --verbose)
        VERBOSE=$((VERBOSE + 1))
    ;;
    -v|--version)
    echo "${tool} version ${VERSION}"
    exit 0
    ;;
    -*) # unknown
    echo "ERROR: Unknown argument, '${1}'"
    help 1
    ;;
    *) # positional arg
    POSITIONAL+=("$1")
    ;;
  esac
  shift
done
set -- "${POSITIONAL[@]}" # restore positional parameters

## Check correct number of positional parameters
if [ $# -ne 2 -a "${UNITTESTMODE}" == "no" ]; then
  help
fi

if [ "${UNITTESTMODE}" == "no" ]; then
    module load NCO/5.0.3-intel-2021b
    ulimit -s unlimited
fi

JOBLID=$(date +'%Y%m%d_%H%M%S')
if [ "${UNITTESTMODE}" == "no" ]; then
    ## We have a bit of chicken and egg here.
    ## We can't log until we have a <logfilename> but
    ## We can't create a <logfilename> until we have a
    ## (possibly newly created) output directory.
    logmsgs=""
    ncrcat=$(which ncrcat)
    # The second positional argument is a location for output and logging
    if [ ! -d "${2}" ]; then
        logmsgs="Creating <output path>, '${2}'"
        mkdir -p ${2}
    fi
    outpath=$(realpath "${2}")
    logfilename="${outpath}/${tool}.log.${JOBLID}"

    if [ -f "${logfilename}" ]; then
        rm -f ${logfilename}
    fi
    touch ${logfilename}
    if [ -n "${logmsgs}" ]; then
        log "${logmsgs}"
    fi

    # The first positional argument is the path to an existing case
    if [ ! -d "${1}" ]; then
        ERRMSG="<archive case path>, '${1}', does not exist"
        log "ERROR: ${ERRMSG}"
        ERRCODE=${ERR_BADARG}
        exit ${ERRCODE}
    fi
    casepath=$(realpath "${1}")
    casename=$(basename ${casepath})
fi

if [ "${UNITTESTMODE}" == "no" ]; then
    touch ${logfilename}
    log "===================="
    log "${tool}"
    log "===================="
    log "NorESM Case: $casepath"
    log "Output Dir: ${outpath}"
    log "Compressing components: ${COMPONENTS[@]}"
    if [ ${MOVE} -eq 1 ]; then
      log "Move/Delete Dir: '${MOVEDIR}'"
    else
        log "Not moving any files"
    fi
    if [ "${MERGETYPE}" == "monthly" ]; then
        log "Merge files per month"
    elif [ "${MERGETYPE}" == "yearly" ]; then
        log "Merge files per year"
    elif [ "${MERGETYPE}" == "mergeall" ]; then
        log "Merge all files into one sequence"
    else
        ERRMSG="Undefined merge type, '${MERGETYPE}'."
        log "ERROR: ${ERRMSG}"
    fi
    log "Compression: ${COMPRESS}"
    log "Threads: ${NTHREADS}"
    log "Message Verbosity: Level ${VERBOSE}"
    log "===================="
    if [ ${VERBOSE} -ge 1 ]; then
        log "cprnc = ${cprnc}"
        log "xxhsum = ${xxhsum}"
        log "ncrcat = $(which ncrcat)"
        log "ncks = $(which ncks)"
        log "===================="
    fi
fi

##set -x

report_job_status() {
    ## Given a status code ($1) and the number of created jobs ($2),
    ##    check for errors.
    ## If any errors are found, report on the status of each job and
    ##    number of errors it encountered.
    local hfile
    local res=${1}
    local -i job_num=${2}
    local -i nfails
    local -i tjobs            # Total number of jobs
    local -i nerrs=${#error_reports[@]}
    # Report on jobs run and any errors
    tjobs=${#job_status[@]}
    if [ ${tjobs} -ne ${job_num} ]; then
        ERRMSG="Internal error, job mismatch (${tjobs} != ${job_num})"
        log "ERROR ${ERRMSG}"
    fi
    nfails=$(echo "${fail_report[@]}" | tr ' ' '+' | bc)
    if [ ${nfails} -gt 0 ]; then
        for hfile in ${!job_status[@]}; do
            log "Job status for '${hfile}': ${job_status[${hfile}]}"
            if [ ${fail_report[${hfile}]} -gt 0 ]; then
                log "Output file: ${job_num} had ${fail_report[${job_num}]} FAILures"
            fi
        done
    elif [ ${nerrs} -eq 0 -a ${res} -eq 0 -a "${UNITTESTMODE}" == "no" ]; then
        log ${logile} "All tests PASSed"
    elif [ ${nerrs} -gt 0 ]; then
        log "Internal errors or errors running tools reported"
        for hfile in ${!error_reports[@]}; do
            log "${error_reports[${hfile}]}"
        done
    fi
}

__cleanup() {
    # Cleanup on any error condition
    local res=$?
    if [ -n "${ERRMSG}" ]; then
        log ""
        log -e "ERROR: ${ERRMSG}"
    fi
    log ""
    if [ ${res} -ne 0 ]; then
        log "Exit code ${res} signaled"
        log "${tool} canceled: cleaning up .tmp files..."
        if [ -z "${ERRMSG}" ]; then
            log "The tool can be restarted and should continue conversion."
        fi
    fi
    rm -f ${outpath}/*.tmp
    report_job_status ${res} ${#job_status[@]}
    if [ ${ERRCODE} -ne 0 ]; then
        exit ${ERRCODE}
    else
        exit ${res}
    fi
}

__interrupt() {
    ## Special cleanup catch for when the user hits ^C
    ERRMSG="Job interrupted by user"
    exit ${ERR_INTERRUPT}
}

trap __cleanup EXIT
trap __interrupt SIGINT

num_jobs() {
    # Return the number of child processes
    local bash_pid=$$
    local children=$(ps -eo ppid | grep -w $bash_pid)
    echo "${children}"
}

get_file_set_name() {
    # Given a filename ($1), return the instance string and history file number.
    # For a multi-instance run, this will look like xxx_0001.h1 or xxx_0002.h3, etc.
    # For a single instance run, the return val will look like xxx.h1 or xxx.h2, etc.
    # In both cases, xxx will be a model name such as cam or clm.
    echo "$(echo ${1} | cut -d'.' -f2-3)"
}

get_file_set_names() {
    # Given an array of files ($1), return the set of instance strings and history file numbers.
    # For a multi-instance run, these will look like xxx_0001.h1, xxx_0002.h1. etc.
    # For a single instance run, the entries will look like xxx.h1, xxx.h2, etc.
    # In both cases, xxx will be a model name such as cam or clm.
    local istrs=($@)
    local set_names
    set_names=($(echo ${istrs[@]} | tr ' ' '\n' | cut -d'.' -f2-3 | sort | uniq))
    echo "$(echo ${set_names[@]} | sed -e 's/ /:/g')"
}

convert_time_to_date() {
    # Given a time ($1) and a base year ($2), return the date string (yyyyymmdd)
    # If $3 is present, it should be a calendar type. The default is a
    # fixed 365 day year calendar.
    local day
    local month
    local year
    local ytd
    local tstr=${1}
    local year0=${2}

    if [ -n "${3}" -a "${3}" != "365" ]; then
        echo "ERROR: Calendar type, '${3}', not supported"
    else
        # Round up fractional days
        tstr=$(echo "(${tstr} + 0.99999) / 1" | bc --quiet)
        year=$(echo "((${tstr} - 1) / 365) + ${year0}" | bc --quiet)
        day=$(echo "(((${tstr} - 1) % 365) + 1.99999) / 1" | bc --quiet)
        month=12
        for ytd in 334 304 273 243 212 181 151 120 90 59 31; do
            if [ ${day} -gt ${ytd} ]; then
                day=$((day - ytd))
                break
            else
                month=$((month - 1))
            fi
        done
        #
        if [ ${year} -gt 99999 ]; then
            echo $(printf "%06d%02d%02d" ${year} ${month} ${day})
        elif [ ${year} -gt 9999 ]; then
            echo $(printf "%05d%02d%02d" ${year} ${month} ${day})
        else
            echo $(printf "%04d%02d%02d" ${year} ${month} ${day})
        fi
    fi
}

get_file_date_field() {
    # Given a filename ($1), return its date field. This is the information after
    # the history file number and incorporates the year and optionally the month, day, and time.
    echo "$(echo ${1} | cut -d'.' -f4)"
}

get_hist_file_info() {
    ## Given a path to a history file ($1), return the number of frames and the
    ## array values of a chosen variable ($2) (one for each frame)
    ## $3 is a format string to be used with '-s'
    local fvals
    local res

    if [ ${VERBOSE} -ge 2 ]; then
      qlog "Calling ncks -H -C -v ${2} -s ${3} ${1}"
    fi
    fvals=($(ncks -H -C -v ${2} -s ${3} ${1}))
    res=$?
    if [ ${res} -ne 0 ]; then
        ERRMSG="get_hist_file_info: ERROR ${res} extracting ${2} from test file ${1}"
        log "${ERRMSG}"
        error_reports[${1}]="${ERRMSG}"
        ERRCODE=${ERR_NCKS_MDATA}
        exit ${ERRCODE}
    fi
    echo "${#fvals[@]}:$(echo ${fvals[@]} | tr ' ' ':')"
}

is_yearly_hist_file() {
    ## Given a path to a history file ($1), return 0 if the file appears to
    ##    be a yearly file (date field of filename has only a year).
    ## Return 1 otherwise.

    if [[ "${1}" =~ \.[0-9]{4,5}\.nc$ ]]; then
        return 0
    else
        return 1
    fi
}

is_monthly_hist_file() {
    ## Given a path to a history file ($1), return 0 if the file appears to
    ##    be a monthly file (date field of filename has only a year and month).
    ## Return 1 otherwise.

    if [[ "${1}" =~ \.[0-9]{4,5}[-][0-9]{2}\.nc$ ]]; then
        return 0
    else
        return 1
    fi
}

get_date_from_filename() {
    ## Given a path to a history file ($1), return the date as yyyyxxxx for
    ## yearly history files, yyyymmxx for monthly history files and yyyymmdd
    ## for other files
    local datefield="$(echo ${1} | cut -d'.' -f4)"
    local year="$(echo ${datefield} | cut -d'-' -f1)"
    local month="$(echo ${datefield} | cut -d'-' -f2 -s)"
    local day="$(echo ${datefield} | cut -d'-' -f3 -s)"
    # Fill in xx for day if blank (e.g., for monthly files)
    if [ -z "${month}" ]; then
        month="xx"
    fi
    if [ -z "${day}" ]; then
        day="xx"
    fi

    echo ${year}${month}${day}
}

get_atm_hist_file_info() {
    ## Given a path to an CAM history file ($1), return the number of frames and the
    ## date array values (one for each frame)

    local dates
    if is_monthly_hist_file "${1}"; then
        dates="1:$(get_date_from_filename ${1})"
    else
        dates=$(get_hist_file_info "${1}" "date" "%d\n")
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
    fi
    echo ${dates}
}

get_lnd_hist_file_info() {
    ## Given a path to an CTSM history file ($1), return the number of frames and the
    ## date array values (one for each frame)

    local dates
    if is_monthly_hist_file "${1}"; then
        dates="1:$(get_date_from_filename ${1})"
    else
        dates=$(get_hist_file_info "${1}" "mcdate" "%d\n")
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
    fi
    echo ${dates}
}

get_year0_from_time_attrib() {
    ## Given a history file ($1), return the start year if the time variable
    ## is days since a starting year and the calendar is 'noleap'.
    ## Otherwise, throw an error and return an empty string

    local attrib
    local tstr
    local year0=""  # Year calendar begins

    if [ ${VERBOSE} -ge 2 ]; then
      qlog "Calling ncks --metadata -C -v time ${1}"
    fi
    attrib="$(ncks --metadata -C -v time ${1})"
    res=$?
    if [ ${res} -ne 0 ]; then
        ERRMSG="ERROR ${res} extracting time metadata from test file ${1}"
        log "${ERRMSG}"
        error_reports[${1}]="${ERRMSG}"
        ERRCODE=${ERR_BAD_YEAR0}
        exit ${ERRCODE}
    fi
    tstr=$(echo "${attrib}" | grep time:calendar)
    if [[ ! "${tstr,,}" =~ "noleap" ]]; then
        ERRMSG="Unsupported time calendar for '${1}', '${tstr}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_UNSUPPORT_CAL}
        exit ${ERRCODE}
    fi
    tstr=$(echo "${attrib}" | grep time:units)
    if [[ ! "${tstr}" =~ days\ since\ ([0-9]{4,})-01-01\ 00:00 ]]; then
        ERRMSG="Unsupported time units for '${1}', '${tstr}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_UNSUPPORT_TIME}
        exit ${ERRCODE}
    else
        year0="${BASH_REMATCH[1]}"
    fi
    echo "${year0}"
}

get_ice_hist_file_info() {
    ## Given a path to a CICE history file ($1), return the number of frames and the
    ## date array values (one for each frame)
    ## CICE (at least CICE5) has time as "days since yyyy-01-01 00:00:00" attribute
    ##    and a noleap calendar. Check these attributes and derive the date from the time

    local times=()
    local tind
    local year0  # Year calendar begins

    year0="$(get_year0_from_time_attrib ${1})"
    if [ -n "${ERRMSG}" ]; then
        exit ${ERRCODE}
    fi
    if [ -n "${year0}" ]; then
        times=($(echo $(get_hist_file_info "${1}" "time" "%f\n") | tr ':' ' '))
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
    fi
    ## Convert times to dates
    for tind in $(seq 1 $((${#times[@]} - 1))); do
        times[${tind}]=$(convert_time_to_date ${times[${tind}]} ${year0})
    done
    echo  ${times[@]} | tr ' ' ':'
}

get_ocn_hist_file_info() {
    ## Given a path to BLOM history file ($1), return the number of frames and the
    ## date array values (one for each frame)
    ## BLOM has time as "days since yyyy-01-01 00:00:00" attribute
    ##    and a noleap calendar. Check these attributes and derive the date from the time

    local dates
    local times=()
    local tind
    local year0  # Year calendar begins

    if is_yearly_hist_file "${1}"; then
        dates="1:$(get_date_from_filename ${1})"
    else
        year0="$(get_year0_from_time_attrib ${1})"
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
        if [ -n "${year0}" ]; then
            times=($(echo $(get_hist_file_info "${1}" "time" "%f\n") | tr ':' ' '))
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        fi
        ## Convert times to dates
        for tind in $(seq 1 $((${#times[@]} - 1))); do
            times[${tind}]=$(convert_time_to_date ${times[${tind}]} ${year0})
        done
        dates="$(echo  ${times[@]} | tr ' ' ':')"
    fi
    echo ${dates}
}

get_rof_hist_file_info() {
    ## Given a path to an MOSART history file ($1), return the number of frames and the
    ## date array values (one for each frame)

    local dates
    if is_yearly_hist_file "${1}"; then
        dates="1:$(get_date_from_filename ${1})"
    elif is_monthly_hist_file "${1}"; then
        dates="1:$(get_date_from_filename ${1})"
    else
        dates=$(get_hist_file_info "${1}" "mcdate" "%d\n")
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
    fi
    echo "${dates}"
}

greater_than() {
    # Return zero if $1 > $2, one otherwise
    if [ -z "${1}" ]; then
        ERRMSG="greater_than requires two arguments, was called with none"
        log "${ERRMSG}"
        ERRCODE=${ERR_BADARG_GT}
        exit ${ERRCODE}
    elif [ -z "${2}" ]; then
        ERRMSG="greater_than requires two arguments, was called with '${1}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_BADARG_GT}
        exit ${ERRCODE}
    fi
    bcval="$(echo "${1} > ${2}" | bc --quiet)"
    if [ -z "${bcval}" ]; then
        ERRMSG="Bad bc call in greater_than: echo \"${1} > ${2}\" | bc --quiet"
        log "${ERRMSG}"
        ERRCODE=${ERR_BADARG_GT}
        exit ${ERRCODE}
    fi
    return $((1 - bcval));
}

less_than() {
    # Return zero if $1 < $2, one otherwise
    local bcval # Output from bc
    if [ -z "${1}" ]; then
        ERRMSG="less_than requires two arguments, was called with none"
        log "ERROR: ${ERRMSG}"
        ERRCODE=${ERR_BADARG_LT}
        exit ${ERRCODE}
    elif [ -z "${2}" ]; then
        ERRMSG="less_than requires two arguments, was called with '${1}'"
        log "ERROR: ${ERRMSG}"
        ERRCODE=${ERR_BADARG_LT}
        exit ${ERRCODE}
    fi
    bcval="$(echo "${1} < ${2}" | bc --quiet)"
    if [ -z "${bcval}" ]; then
        ERRMSG="Bad bc call in less_than: echo \"${1} < ${2}\" | bc --quiet"
        log "ERROR: ${ERRMSG}"
        ERRCODE=${ERR_BADARG_LT}
        exit ${ERRCODE}
    fi
    return $((1 - bcval));
}

bnds_from_array() {
    ## Return the minimum and maximum values in the input array
    local minval=""
    local maxval=""

    for frame in $@; do
        if [ -z "${minval}" ]; then
            minval="${frame}"
        fi
        if [ -z "${maxval}" ]; then
            maxval="${frame}"
        fi
        if less_than ${frame} ${minval}; then
            minval="${frame}"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        fi
        if greater_than ${frame} ${minval}; then
            maxval="${frame}"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        fi
    done
    echo "${minval},${maxval}"
}

get_year_from_date() {
    ## Given a date string, return the year
    if [ ${#1} -lt 8 ]; then
        ERRMSG="ERROR: get_year_from_date; Bad date string, '${1}'"
        log "${ERRMSG}"
        error_reports["get_year_from_date_${1}"]="${ERRMSG}"
        ERRCODE=${ERR_BAD_DATESTR}
        exit ${ERRCODE}
    else
        echo "${1:0:-4}"
    fi
}

get_month_from_date() {
    ## Given a date string, return the month
    if [ ${#1} -lt 8 ]; then
        ERRMSG="ERROR: get_month_from_date; Bad date string, '${1}'"
        log "${ERRMSG}"
        error_reports["get_month_from_date_${1}"]="${ERRMSG}"
        ERRCODE=${ERR_BAD_DATESTR}
        exit ${ERRCODE}
    else
        echo "${1:${#1}-4:-2}"
    fi
}

get_day_from_date() {
    ## Given a date string, return the day of the month
    if [ ${#1} -lt 8 ]; then
        ERRMSG="ERROR: get_day_from_date; Bad date string, '${1}'"
        log "${ERRMSG}"
        error_reports["get_day_from_date_${1}"]="${ERRMSG}"
        ERRCODE=${ERR_BAD_DATESTR}
        exit ${ERRCODE}
    fi
    echo "${1:${#1}-2}"
}

get_range_year() {
    ## Given a "date string" from get_xxx_hist_file_info, return
    ## the year of all the dates or an error if more than one year
    ## is found.
    ## $1 is the date string, $2 is a filename for an error message
    local datestr
    local file="${2}"
    local year=-1
    local tyear
    if [ -z "${file}" ]; then
        file="file"
    fi
    for datestr in $(echo ${1} | cut -d':' -f2- | tr ':' ' '); do
        tyear="$(get_year_from_date ${datestr})"
        if [ -n "${ERRMSG}" ]; then
            break
        fi
        if [ ${year} -lt 0 ]; then
            year="${tyear}"
        elif [[ ! "${tyear}" =~ ^[0-9]+$ ]]; then
            ERRMSG="get_range_year: Invalid year found in ${file}"
            year="ERROR"
            log "${ERRMSG}"
            ERRCODE=${ERR_BADYEAR}
            break
        elif [ "${year}" != "${tyear}" ]; then
            ERRMSG="get_range_year: Multiple years found in ${file}"
            year="ERROR"
            log "${ERRMSG}"
            ERRCODE=${ERR_MULTYEARS}
            break
        fi
    done
    if [ -n "${ERRMSG}" ]; then
        exit ${ERRCODE}
    fi
    echo "${year}"
}

get_range_month() {
    ## Given a "date string" from get_xxx_hist_file_info, return
    ## the year:month of all the dates or an error if more than one month
    ## is found.
    ## $1 is the date string, $2 is a filename for an error message
    local datestr
    local file="${2}"
    local month=-1
    local tmonth
    local year=-1
    local tyear
    if [ -z "${file}" ]; then
        file="file"
    fi
    for datestr in $(echo ${1} | cut -d':' -f2- | tr ':' ' '); do
        tyear="$(get_year_from_date ${datestr})"
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
        tmonth="$(get_month_from_date ${datestr})"
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
        if [ ${year} -lt 0 ]; then
            year="${tyear}"
            if [ ${month} -ge 0 ]; then
                ERRMSG="get_range_month: Internal error, month = ${month}"
                month="ERROR"
                log "${ERRMSG}"
                ERRCODE=${ERR_INTERNAL}
                exit ${ERRCODE}
            else
                month="${tmonth}"
            fi
        elif [ ${month} -lt 0 ]; then
            ERRMSG="get_range_month: Internal error, year = ${year}"
            month="ERROR"
            log "${ERRMSG}"
            ERRCODE=${ERR_INTERNAL}
            exit ${ERRCODE}
        elif [[ ! "${tyear}" =~ ^[0-9]+$ ]]; then
            ERRMSG="get_range_month: Invalid year found in ${file}"
            year="ERROR"
            log "${ERRMSG}"
            ERRCODE=${ERR_INTERNAL}
            exit ${ERRCODE}
        elif [[ ! "${tmonth}" =~ ^[0-9]+$ ]]; then
            ERRMSG="get_range_month: Invalid month found in ${file}"
            month="ERROR"
            log "${ERRMSG}"
            ERRCODE=${ERR_INTERNAL}
            exit ${ERRCODE}
        elif [ "${year}" != "${tyear}" ]; then
            ERRMSG="get_range_month: Multiple years found in ${file}"
            month="ERROR"
            log "${ERRMSG}"
            ERRCODE=${ERR_MULTYEARS}
            exit ${ERRCODE}
        elif [ "${month}" != "${tmonth}" ]; then
            ERRMSG="get_range_month: Multiple months found in ${file}"
            month="ERROR"
            log "${ERRMSG}"
            ERRCODE=${ERR_MULTMONTHS}
            exit ${ERRCODE}
        fi
    done
    echo "${year}:${month}"
}

get_file_date() {
    ## Given a history file ($1), a component type ($2) and a merge type ($3),
    ## find the applicable date in the file or generate an error.
    ## The function is only valid for the 'yearly' and 'monthly' merge types.
    ## mergeall merges use all the data in each file.
    local hfile="${1}"
    local comp="${2}"
    local merge="${3}"
    local tdate=""
    local tdates=""
    if [ ! -f "${hfile}" ]; then
        ERRMSG="get_file_date: File does not exist, '${hfile}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_MISSING_FILE}
        exit ${ERRCODE}
    elif [ "${merge}" == "mergeall" ]; then
        ERRMSG="get_file_date: Unsupported merge type, '${merge}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_UNSUPPORT_MERGE}
        exit ${ERRCODE}
    elif [ "${merge}" != "yearly" -a "${merge}" != "monthly" ]; then
        ERRMSG="get_file_date: Unrecognized merge type, '${merge}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_BAD_MERGETYPE}
        exit ${ERRCODE}
    else
        if [ "${comp}" == "atm" ]; then
            tdates="$(get_atm_hist_file_info ${hfile})"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        elif [ "${comp}" == "ice" ]; then
            tdates="$(get_ice_hist_file_info ${hfile})"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        elif [ "${comp}" == "lnd" ]; then
            tdates="$(get_lnd_hist_file_info ${hfile})"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        elif [ "${comp}" == "ocn" ]; then
            tdates="$(get_ocn_hist_file_info ${hfile})"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        elif [ "${comp}" == "rof" ]; then
            tdates="$(get_rof_hist_file_info ${hfile})"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        else
            ERRMSG="get_file_date: Unrecognized component type, '${comp}'"
            log "${ERRMSG}"
            ERRCODE=${ERR_BAD_COMPTYPE}
            exit ${ERRCODE}
        fi
    fi
    if [ -n "${tdates}" ]; then
        if [ "${merge}" == "yearly" ]; then
            tdate="$(get_range_year ${tdates} ${hfile})"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        elif [ "${merge}" == "monthly" ]; then
            tdate="$(get_range_month ${tdates} ${hfile})"
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        fi
    fi
    echo "${tdate}"
}

get_xxhsum_filename() {
    ## Given a filename or directory ($1), return the name for the xxhsum filename
    ## to use for compression jobs in that directory.
    local cdir=""  # The name of the directory where $1 is located
    local fname="" # The xxhsum filename
    local pdir     # Parent directory name
    if [ -f "${1}" ]; then
        cdir="$(realpath $(dirname ${1}))"
    elif [ -d "$(realpath ${1})" ]; then
        cdir="$(realpath ${1})"
    else
        ERRMSG="get_xxhsum_filename: Invalid filename or directory input, '${1}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_INTERNAL}
        exit ${ERRCODE}
    fi
    if [ -n "${cdir}" ]; then
        if [ "$(basename ${cdir})" == "hist" ]; then
            ## We are in a component directory, grab the component name
            ## and the casedir name (above component)
            pdir="$(dirname ${cdir})" # e.g., ice, ocn
            fname="$(basename $(dirname ${pdir}))_$(basename ${pdir})"
        elif [ -f "${1}" ]; then
            ## Take the case name from the filename
            fname=$(echo $(basename "${1}") | cut -d'.' -f1)
        else
            ## Just take the name of the directory
            fname="$(basename ${cdir})"
        fi
        echo "${cdir}/${fname}_${JOBLID}.xxhsum"
    else
        ERRMSG="get_xxhsum_filename: Invalid filename or directory input, '${1}'"
        log "${ERRMSG}"
        ERRCODE=${ERR_INTERNAL}
        exit ${ERRCODE}
    fi
}

compare_frames() {
    ## Compare the output file ($1) with some of the corresponding
    ## input files ($4-)
    ## $2 is the component type (e.g., atm, ice)
    ## $3 is a unique job number to allow thread-safe temporary filenames
    local outfile=${1}
    local comp=${2}
    local job_num=${3}
    shift 3
    local files=($@)
    local check_files              # List of source file indices to check
    local diff_output              # cprnc output to parse
    local diff_title               # First part of filename for cprnc output
    local endmsg                   # File checking message
    local ftimes                   # Array of time (or date) fields from an input file
    local nco_args                 # Inputs for the next NCO call
    local -i nfail=0               # Number of failed source file checks
    local -i numfiles=${#files[@]} # Number of input files
    local -i num_check_files       # Number of source files to check
    local pass                     # Var used to test cprnc pass / fail
    local passmsg="."              # Pass / Fail message
    local pl=""                    # 's' for multiple test frames
    local res                      # Test if last command succeeded (zero return)
    local sfile                    # Source file currently being checked
    local test_filename            # Unique temp filename for extracted frames
    local timevar                  # Variable name containing the time (or date) information

    test_filename="${outpath}/test_frame_j${job_num}_$(date +'%Y%m%d%H%M%S').nc"
    if [ -f "${test_filename}" ]; then
        # This should not happen!
        ERRMSG="Temp filename, '${test_filename}', already exists"
        log "INTERNAL ERROR: ${ERRMSG}"
        job_status[${outfile}]="ERROR: ${ERRMSG}"
        nfail=$((nfail + 1))
        fail_report[${outfile}]=${nfail}
        ERRCODE=${ERR_INTERNAL}
        exit ${ERRCODE}
    fi
    if [ "${COMPARE}" == "Spot" ]; then
        num_check_files=$(((${numfiles} + 7) / 10)) # Plus first and last source file
        if [ ${numfiles} -gt 0 ]; then
            check_files=(1)
        fi
        for snum in $(seq ${num_check_files}); do
            check_files+=($((snum*(numfiles + 1) / (num_check_files + 1))))
        done
        if [ ${numfiles} -gt 1 ]; then
            check_files+=($numfiles)
        fi
        log "Spot checking ${#check_files[@]} source files against the corresponding frame(s) from ${outfile}"
        endmsg="Done spot checking ${outfile} against selected source files"
        passmsg=", all PASS."
        job_status[${outfile}]="in spot check"
    elif [ "${COMPARE}" == "Full" ]; then
        check_frames=($(seq ${numfiles}))
        log "Checking each source file against the corresponding frame(s) from ${outfile}."
        endmsg="Done checking all frames from ${outfile} against the corresponding source files"
        passmsg=", all PASS."
        job_status[${outfile}]="in full check"
    else
        check_frames=()
        endmsg="Skipping source file check"
        job_status[${outfile}]="pass"
    fi
    diff_title="cprnc_diff_frame_j${job_num}.$(echo $(basename ${outfile}) | cut -d'.' -f3-4)"
    for check_file in ${check_files[@]}; do
        ## Find the source filename for this check
        sfile=${files[${check_file}-1]}
        if [ -z "${sfile}" ]; then
            ERRMSG="empty entry in compare_frames (\${files[${check_file}-1]})"
            log "INTERNAL ERROR: ${ERRMSG}"
            log "INTERNAL ERROR: check_files=(${check_files[@]})"
            log "INTERNAL ERROR: files=(${files[@]})"
            job_status[${outfile}]="INTERNAL ERROR: ${ERRMSG}"
            nfail=$((nfail + 1))
            fail_report[${outfile}]=${nfail}
            ERRCODE=${ERR_INTERNAL}
            exit ${ERRCODE}
        elif [ ! -f "${sfile}" ]; then
            ERRMSG="file in compare_frames, '${files[${check_file}-1]}', does not exist"
            log "INTERNAL ERROR: ${ERRMSG}"
            job_status[${outfile}]="INTERNAL ERROR: ${ERRMSG}"
            nfail=$((nfail + 1))
            fail_report[${outfile}]=${nfail}
            ERRCODE=${ERR_INTERNAL}
            exit ${ERRCODE}
        fi
        ## Extract the time dimension for this file
        timevar="time"
        nco_args="-s %f: -H -C -v ${timevar} ${sfile}"
        if [ ${VERBOSE} -ge 2 ]; then
            qlog "Calling ncks ${nco_args}"
        fi
        ftimes=($(echo $(ncks ${nco_args}) | tr ':' ' '))
        res=$?
        if [ ${res} -ne 0 ]; then
            ERRMSG="${res} extracting time from test file ${check_file}"
            log "ERROR: ${ERRMSG}"
            job_status[${outfile}]="ERROR: ${ERRMSG}"
            nfail=$((nfail + 1))
            fail_report[${outfile}]=${nfail}
            ERRCODE=${ERR_BAD_TIME}
            exit ${ERRCODE}
        fi
        if [ ${#ftimes[@]} -gt 1 ]; then
            pl="s"
        else
            pl=""
        fi
        ## Extract the matching from the output file
        ## For now, set the stride to one.
        ## One could add an option here to only spot check frames,
        ##    however, that means pulling frames out of the source
        ##    file which takes time and space.
        bnds_str="$(bnds_from_array ${ftimes[@]}),1"
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
        nco_args="-d ${timevar},${bnds_str} ${outfile} ${test_filename}"
        if [ "${DRYRUN}" == "yes" ]; then
            log "ncks ${nco_args}"
        else
            if [ ${VERBOSE} -ge 2 ]; then
                qlog "Calling ncks ${nco_args}"
            fi
            ncks ${nco_args}
            res=$?
            if [ ${res} -ne 0 ]; then
                ERRMSG="${res} extracting test frame${pl} from output file"
                log "ERROR: ${ERRMSG}"
                job_status[${outfile}]="ERROR: ${ERRMSG}"
                nfail=$((nfail + 1))
                fail_report[${outfile}]=${nfail}
                ERRCODE=${ERR_EXTRACT}
                exit ${ERRCODE}
            fi
        fi
        ## Run cprnc to test output frame against input file
        diff_output="${outpath}/${diff_title}.f${check_file}_$(date +'%Y%m%d%H%M%S').txt"
        if [ -f "${diff_output}" ]; then
            # Yeah, this should not be necessary but . . .
            rm -f ${diff_output}
        fi
        if [ "${DRYRUN}" == "yes" ]; then
            log "cprnc ${sfile} ${test_filename} > ${diff_output}"
        else
            if [ ${VERBOSE} -ge 2 ]; then
                qlog "Calling ${cprnc} ${sfile} ${test_filename} > ${diff_output}"
            fi
            ${cprnc} ${sfile} ${test_filename} > ${diff_output}
            res=$?
            if [ ${res} -ne 0 ]; then
                ERRMSG="${res} running cprnc to verify output frame${pl} from file, ${sfile}"
                log "ERROR: ${ERRMSG}"
                job_status[${outfile}]="ERROR: ${ERRMSG}"
                nfail=$((nfail + 1))
                fail_report[${outfile}]=${nfail}
                ERRCODE=${ERR_CPRNC}
                exit ${ERRCODE}
            fi
            grep 'diff_test' ${diff_output} | grep --quiet IDENTICAL
            pass=$?
            if [ $pass -eq 0 ]; then
                log "Checking ${sfile} against output frame${pl} . . . PASS"
            else
                ERRMSG="Checking ${sfile} against output frame${pl} . . . FAIL"
                log "${ERRMSG}"
                log "cprnc output saved in ${diff_output}"
                job_status[${outfile}]="ERROR: ${ERRMSG}"
                nfail=$((nfail + 1))
            fi
        fi
        ## Cleanup
        rm -f ${test_filename}
        if [ $pass -eq 0 ]; then
            rm -f ${diff_output}
        fi
    done
    if [ ${nfail} -gt 0 ]; then
        passmsg=", ${nfail} comparison FAILures."
    else
      job_status[${outfile}]="pass"
    fi
    fail_report[${outfile}]=${nfail}
    log "${endmsg}${passmsg}"
}

convert_cmd() {
    ## Compress files ($4-) into a single file, $1.
    ## $3 is the model type (e.g., atm, lnd)
    ## $4 is a unique job number to allow thread-safe temporary filenames
    local outfile=${1}
    local comp=${2}
    local job_num=${3}
    shift 3
    local files=($@)
    local nfil
    local numfiles="${#files[@]}"
    local reffile="${files[-1]}"
    local vmsg
    local xxhsumfile

    if [ ${VERBOSE} -ge 1 ]; then
        vmsg="Concatenating ${#files[@]} to ${outfile} using level ${COMPRESS} compression"
        vmsg="${vmsg}\nFiles to concatenate are:\n$(echo ${files[@]} | tr ' ' '\n')"
        qlog -e "${vmsg}"
    fi
    job_status[${outfile}]="in compress"
    if [ ${#files[@]} -eq 0 ]; then
        ERRMSG="INTERNAL ERROR: No files to compress to '${outfile}'?"
        error_reports[${outfile}]="${ERRMSG}"
        log "${ERRMSG}"
        ERRCODE=${ERR_NOCOMPRESS}
        exit ${ERRCODE}
    elif [ "${DRYRUN}" == "yes" ]; then
        log "${ncrcat} -O -4 -L ${COMPRESS} ${files[@]} -o ${outfile}"
    else
      if [ ${VERBOSE} -ge 2 ]; then
        qlog "Calling: ${ncrcat} -O -4 -L ${COMPRESS} ${files[@]} -o ${outfile}"
      fi
        ${ncrcat} -O -4 -L ${COMPRESS} ${files[@]} -o ${outfile}
        res=$?
        if [ ${res} -ne 0 ]; then
            ERRMSG="ERROR ${res} concatenating ${files[@]}"
            log "${ERRMSG}"
            error_reports[${1}]="${ERRMSG}"
            ERRCODE=${ERR_NCRCAT}
            exit ${ERRCODE}
        fi
    fi
    job_status[${outfile}]="compressed"
    fail_report[${outfile}]=0

    if [ -f "${outfile}" ]; then
        xxhsumfile=$(get_xxhsum_filename ${outfile})
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
        if [ "${DRYRUN}" == "yes" ]; then
            log "${xxhsum} -H2 ${outfile} >> ${xxhsumfile}"
        else
            touch -r $reffile ${outfile}
            ${xxhsum} -H2 ${outfile} >> ${xxhsumfile}
        fi
        if [ ${numfiles} -eq 1 ]; then
            nfil="file"
        else
            nfil="files"
        fi
        if [ "${DRYRUN}" == "yes" ]; then
            log "DRYRUN: $(basename ${outfile}): ${numfiles} ${nfil} merged"
        else
            log "DONE: $(basename ${outfile}): ${numfiles} ${nfil} merged"
        fi
        compare_frames "${outfile}" ${comp} ${job_num} ${files[@]}
        if [ -n "${ERRMSG}" ]; then
            exit ${ERRCODE}
        fi
        if [ ${MOVE} -eq 1 ]; then
            if [ "${DRYRUN}" == "yes" ]; then
                log "Not moving source files (DRYRUN)"
            else
                mv ${files[@]} ${MOVEDIR}
            fi
        fi
    fi
}

convert_loop() {
    # Loop through components and concatenate its history files
    # Takes a single argument, a log file for echoing output
    local cname               # Loop index
    local comp                # Current component name (e.g., atm, ice)
    local comparr             # Temp array
    local compnames           # Array with the set of model(_<inst>) instances to process
    local currdir="$(pwd -P)"
    local -i nexttime         # Keep track of the next time to display waiting message
    local -A dates            # Array keyed by date (year or year:month) with a list of files to process
    local hpatt               # Component type dependent file matching
    local file_list           # The current list of files to compress
    local hfile               # Loop index
    local hist_files=()       # List of all history files found
    local -i job_num=0        # Current compression job
    local mod                 # The name of the model (e.g., cam, cice)
    local msg                 # For constructing log messages
    local multiout="no"       # Create output directory for each component
    local -i njobs            # Current number of running jobs
    local outfile             # Filename for compressed output file
    local outdir              # Location of compressed files
    local setname             # Temp variable to hold a file set name
    local tdate               # Temporary date field
    if  [ ${#COMPONENTS[@]} -eq 0 ]; then
        COMPONENTS+=("ice:cice")
    elif [ ${#COMPONENTS[@]} -gt 1 ]; then
      multiout="yes"
    fi
    for component in ${COMPONENTS[@]}; do
        comparr=(${component//:/ })
        comp=${comparr[0]}
        mod=${comparr[1]}
        case $comp in
        atm) hpatt="h[0-9]\{1,2\}";;
        lnd) hpatt="[.]h[0-9]\{1,2\}";;
        ice) hpatt="[.]h[0-9]\{0,2\}";;
        ocn) hpatt="[.]h[a-z]\{1,4\}";;
        rof) hpatt="[.]h[0-9]\{1,2\}";;
        esac
        if [ ! -d "${casepath}/${comp}/hist" ]; then
            log "WARNING: case path, '${casepath}/${comp}/hist', not found, skipping"
            continue
        fi
        cd ${casepath}/${comp}/hist
        log "--------------------"
        hist_files=($(ls | grep -e "${casename}[.]${mod}.*${hpatt}.*[.]nc$"))
        log "${comp} hist files: ${#hist_files[@]}"
        comparr=$(get_file_set_names ${hist_files[@]})
        compnames=(${comparr//:/ })
        if [ "${MERGETYPE}" == "yearly" -o "${MERGETYPE}" == "monthly" ]; then
            for cname in ${compnames[@]}; do
                # Create a dictionary of every matching file. Key is the date field,
                #  the value is filename.
                # We assume that all file sets encompass the same dates.
                # Also, gather all the dates (years or year:month pairs)
                dates=()
                for hfile in ${hist_files[@]}; do
                    if [ "$(get_file_set_name ${hfile})" == "${cname}" ]; then
                        tdate="$(get_file_date ${hfile} ${comp} ${MERGETYPE})"
                        if [ -n "${ERRMSG}" ]; then
                            break
                        fi
                        if [ -z "${tdate}" -o -n "$(echo ${tdate} | grep [^0-9:])" ]; then
                            ERRMSG="convert_loop: Bad date from '${hfile}', '${tdate}'"
                            ERRCODE=${ERR_BAD_DATESTR}
                            break
                        fi
                        if [ -n "dates[${tdate}]" ]; then
                            dates["${tdate}"]="${dates[${tdate}]}:${hfile}"
                        else
                            dates["${tdate}"]="${hfile}"
                        fi
                    fi
                done
                if [ -n "${ERRMSG}" ]; then
                    log "${ERRMSG}"
                    exit ${ERRCODE}
                fi
                for tdate in ${!dates[@]}; do
                    ((job_num++))
                    log "Compressing ${cname} for ${tdate//:/-}"
                    file_list=(${dates[${tdate}]//:/ })
                    if [ "${multiout}" == "yes" ]; then
                        outdir="${outpath}/${comp}/hist"
                    else
                        outdir="${outpath}"
                    fi
                    if [ ! -d "${outdir}" ]; then
                        mkdir -p "${outdir}"
                    fi
                    outfile="${outdir}/${casename}.${cname}.${tdate//:/-}.nc"
                    msg="$(printf "%4d: Compressing to $(basename ${outfile})\n" ${job_num})"
                    if [ ${#file_list[@]} -eq 0 ]; then
                        log "No files to compress for ${outfile}, skipping"
                        job_status[${outfile}]="skipped (should not happen?)"
                    elif [ ${NTHREADS} -le 1 ]; then
                        log "${msg}"
                        job_status[${outfile}]="created"
                        convert_cmd ${outfile} ${comp} ${job_num} ${file_list[@]}
                        if [ -n "${ERRMSG}" ]; then
                            exit ${ERRCODE}
                        fi
                    else
                        nexttime=$(($(date +%s)))
                        while :; do
                            ## Wait to launch a new conversion until the number of jobs is low enough.
                            njobs=$(jobs -r | wc -l)
                            if [ ${njobs} -lt ${NTHREADS} ]; then
                                if [ -n "${ERRMSG}" ]; then
                                    break
                                fi
                                log "${msg}"
                                job_status[${outfile}]="created"
                                convert_cmd ${outfile} ${comp} ${job_num} ${file_list[@]} &
                                break
                            elif [ ${VERBOSE} -ge 2 -a $(($(date +s))) -gt ${nexttime} ]; then
                                log "Waiting or job thread, currently running ${njobs} / ${NTHREADS}"
                                nexttime=$(($(date +%s) + 60))
                            fi
                            sleep 0.5s
                        done
                        if [ -n "${ERRMSG}" ]; then
                            break
                        fi
                    fi
                done
                if [ -n "${ERRMSG}" ]; then
                    break
                fi
            done
            if [ -n "${ERRMSG}" ]; then
                exit ${ERRCODE}
            fi
        else
            # We will merge all files in each member of compnames.
            for cname in ${compnames[@]}; do
                ((job_num++))
                log "Compressing ${cname}"
                file_list=()
                for  hfile in ${hist_files[@]}; do
                    if [[ ${hfile} =~ ${casename}[.]${cname}[.].*[.]nc ]]; then
                        file_list+=(${hfile})
                    fi
                done
                if [ "${multiout}" == "yes" ]; then
                    outdir="${outpath}/${comp}/hist"
                else
                    outdir="${outpath}"
                fi
                if [ ! -d "${outdir}" ]; then
                    mkdir -p "${outdir}"
                fi
                outfile="${outdir}/${casename}.${cname}.nc"
                msg="$(printf "%4d: Compressing to $(basename ${outfile})\n" ${job_num})"
                if [ ${#file_list[@]} -eq 0 ]; then
                    log "No files to compress for ${outfile}, skipping"
                    job_status[${outfile}]="skipped (should not happen?)"
                elif [ ${NTHREADS} -le 1 ]; then
                    log "${msg}"
                    job_status[${outfile}]="created"
                    convert_cmd ${outfile} ${comp} ${job_num} ${file_list[@]}
                    if [ -n "${ERRMSG}" ]; then
                        exit ${ERRCODE}
                    fi
                else
                    nexttime=$(($(date +%s)))
                    while :; do
                        ## Wait to launch a new conversion until the number of jobs is low enough.
                        njobs=$(jobs -r | wc -l)
                        if [ ${njobs} -lt ${NTHREADS} ]; then
                            if [ -n "${ERRMSG}" ]; then
                                exit ${ERRCODE}
                            fi
                            log "${msg}"
                            job_status[${outfile}]="created"
                            convert_cmd ${outfile} ${comp} ${job_num} ${file_list[@]} &
                            break
                        elif [ ${VERBOSE} -ge 2 -a $(($(date +%s))) -gt ${nexttime} ]; then
                            log "Waiting for job thread, currently running ${njobs} / ${NTHREADS}"
                            nexttime=$(($(date +%s) + 60))
                        fi
                        sleep 0.5s
                    done
                fi
            done
        fi
        cd ${currdir}
    done
    wait
    log "${tool} : completed"
    # Report on jobs run and any errors
    report_job_status 0 ${job_num}
}

if [ $MOVE -eq 1 -a "${UNITTESTMODE}" == "no" ]; then
    if [ "${DRYRUN}" == "yes" ]; then
        log "Not moving source files (DRYRUN)"
    else
        mkdir -p ${MOVEDIR}
    fi
fi

if [ "${DRYRUN}" == "yes" -a "${UNITTESTMODE}" == "no" ]; then
    log "Dry Run, no data files will be created, moved, modified, or deleted."
fi
if [ "${UNITTESTMODE}" == "no" ]; then
    convert_loop
    if [ -n "${ERRMSG}" ]; then
        exit ${ERRCODE}
    fi
fi

if [ ${DELETE} -eq 1 -a "${UNITTESTMODE}" == "no" ];then
    if [ "${DRYRUN}" == "yes" ]; then
        log "Not deleting source files (DRYRUN)"
    else
        printf "Finalize: DELETING the source files in N seconds... "
        for ind in {30..0..-1}; do
            printf "%02d\b\b" $ind; sleep 1
        done
        rm -rf ${MOVEDIR}
    fi
fi
