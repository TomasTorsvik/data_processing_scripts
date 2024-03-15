#! /bin/bash

## Simple unit test for rcat_noresm.sh

scriptdir="$(dirname $0)"
pdir="$(cd ${scriptdir}/..; pwd -P)"
testdir="${pdir}/TestFiles"
rcat_script="${pdir}/PostProc/rcat_noresm.sh"

declare LOGPASS="yes"
declare NUMTESTS=0
declare NUMFAIL=0

perr() {
    ## If the first argument is non-zero, exit the script
    ## If the second argument exists, print it as an error message
    ## With no second argument, print a generic error message

    if [ $1 -ne 0 ]; then
        if [ $# -gt 1 ]; then
            echo "ERROR (${1}): ${2}"
        else
            echo "ERROR ${1}"
        fi
        exit ${1}
    fi
}

check_test() {
    ## Check to see if a test passed or failed
    ## $1 is a test description
    ## $2 is the test result
    ## $3 is the expected result
    NUMTESTS=$((NUMTESTS + 1))
    if [ "${2}" == "${3}" ]; then
        if [ "${LOGPASS}" == "yes" ]; then
            echo "${1}: PASS"
        fi
    else
        NUMFAIL=$((NUMFAIL + 1))
        echo "${1}: FAIL"
        echo "Found:    '${2}'"
        echo "Expected: '${3}'"
    fi
}

if [ $# -eq 1 -a "${1}" == "--fail-only" ]; then
    LOGPASS="no"
elif [ $# -gt 0 ]; then
    echo "$(basename ${0}) [ --fail-only ]"
    exit 1
fi
source ${rcat_script} --unit-test-mode
perr $? "loading rcat_noresm.sh script, '${rcat_script}'"

## Multi-instance (ensemble) test
tstring=()
for inst in $(seq 1 25); do
    tstring+=($(printf "cam_%04d.h1:cam_%04d.h2" ${inst} ${inst}))
done
tstring="$(echo ${tstring[@]} | tr ' ' ':')"
tfiles=($(ls ${testdir}/ensemble/case_ensemble.cam*.h[1-9]*.nc))
ifiles=$(get_file_set_names ${tfiles[@]})
check_test "Ensemble instance string test" "${ifiles}" "${tstring}"

## Single instance test
tfiles=($(ls ${testdir}/casename/case_single.cice*.h[1-9]*.nc))
ifiles=$(get_file_set_names ${tfiles[@]})
check_test "Single instance string test" "${ifiles}" "cice.h1"

## Tests for bnds_from_array
bnds="$(bnds_from_array 2 3 4 5)"
check_test "Simple bnds_from_array test" "${bnds}" "2,5"
bnds="$(bnds_from_array 2 4 6 8 10)"
check_test "Strided bnds_from_array test" "${bnds}" "2,10"
bnds="$(bnds_from_array 2 4 8 10)"
check_test "Inconsistent bnds_from_array test" "${bnds}" "2,10"

## Tests for finding the correct xxhsum filename
jobid="${JOBLID}"
if [ -n "${jobid}" ]; then
  ans="yes"
else
  ans="no"
fi
check_test "Check for JOBLID" "${ans}" "yes"
xxhcase="xxcasename"
xxhdir="${testdir}/${xxhcase}"
ifilename=casename.cice.h.2021-01-16.nc
touch ${xxhdir}/ice/hist/${ifilename}
touch ${xxhdir}/${ifilename}
fname=$(get_xxhsum_filename ${xxhdir})
check_test "xxhsum filename topdir only" ${fname} ${xxhdir}/${xxhcase}_${jobid}.xxhsum
fname=$(get_xxhsum_filename ${xxhdir}/ice/hist/${ifilename})
check_test "xxhsum filename icefile" ${fname} ${xxhdir}/ice/hist/${xxhcase}_ice_${jobid}.xxhsum
fname=$(get_xxhsum_filename ${xxhdir}/ice/hist)
check_test "xxhsum filename ice hist dir" ${fname} ${xxhdir}/ice/hist/${xxhcase}_ice_${jobid}.xxhsum
fname=$(get_xxhsum_filename ${xxhdir}/${ifilename})
check_test "xxhsum filename fileonly" ${fname} ${xxhdir}/casename_${jobid}.xxhsum

## Tests for finding monthly files
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.clm2.h0.1852-02.nc"
if is_monthly_hist_file ${tfile}; then
    tstring="monthly"
else
    tstring="not monthly"
fi
check_test "Monthly file test for '${tfile}'" "${tstring}" "monthly"
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.clm2.h1.1850-03-07-00000.nc"
is_monthly_hist_file ${tfile}
res=$?
check_test "Monthly file test for '${tfile}'" "${res}" "1"
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.cam.h0.1851-12.nc"
is_monthly_hist_file ${tfile}
res=$?
check_test "Monthly file test for '${tfile}'" "${res}" "0"
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.cam.h1.1861-07-25-00000.nc"
is_monthly_hist_file ${tfile}
res=$?
check_test "Monthly file test for '${tfile}'" "${res}" "1"

## Tests for finding date from filename
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.clm2.h0.1852-02.nc"
check_test "date from filename for '${tfile}'" "$(get_date_from_filename ${tfile})" "185202xx"
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.clm2.h1.1850-03-07-00000.nc"
check_test "date from filename for '${tfile}'" "$(get_date_from_filename ${tfile})" "18500307"
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.cam.h0.1851-12.nc"
check_test "date from filename for '${tfile}'" "$(get_date_from_filename ${tfile})" "185112xx"
tfile="NHISTpiaeroxid_f09_tn14_keyClim20201217.cam.h1.1861-07-25-00000.nc"
check_test "date from filename for '${tfile}'" "$(get_date_from_filename ${tfile})" "18610725"

## Tests for finding dates from a history file
tstring="10:20000614:20000615:20000616:20000617:20000618:20000619:20000620:20000621:20000622:20000623"
atm_file="${testdir}/atm_test_file.cam_0001.h1.2000-06-13-00000.nc"
dates="$(get_atm_hist_file_info ${atm_file})"
check_test "CAM dates test" "${dates}" "${tstring}"
years="$(get_range_year ${dates} ${atm_file})"
check_test "CAM year set test" "${years}" "2000"
tstring="1:185112xx"
atm_file="NHISTpiaeroxid_f09_tn14_keyClim20201217.cam.h0.1851-12.nc"
dates="$(get_atm_hist_file_info ${atm_file})"
check_test "CAM h0 file dates test" "${dates}" "${tstring}"
years="$(get_range_year ${dates} ${atm_file})"
check_test "CAM h0 file year set test" "${years}" "1851"
months="$(get_range_month ${dates} ${atm_file})"
check_test "CAM h0 file month set test" "${months}" "1851:12"
ice_file="${testdir}/ice_test_file.cice_0001.h.2000-05.nc"
tstring="1:20000531"
dates="$(get_ice_hist_file_info ${ice_file})"
check_test "CICE dates test" "${dates}" "${tstring}"
years="$(get_range_year ${dates} ${ice_file})"
check_test "CICE year set test" "${years}" "2000"
dates=(31 59 90 120 151 181 212 243 273 304 334 365)
tvals=("00000131" "00000228" "00000331" "00000430" "00000531" "00000630" "00000731" "00000831" "00000930" "00001031" "00001130" "00001231")
for ind in $(seq 0 $((${#dates[@]} - 1))); do
    tstring=$(convert_time_to_date "${dates[${ind}]}" "0")
    check_test "CICE year zero set test ${ind}" "${tstring}" "${tvals[${ind}]}"
done
ocn_file="${testdir}/ocn_test_file.blom.hbgcd.1850-01.nc"
dates=(24226 67038.5 67052.5 67067.5)
tvals=(18660516 19830901 19830915 19830930)
for ind in $(seq 0 $((${#dates[@]} - 1))); do
    tstring=$(convert_time_to_date "${dates[${ind}]}" "1800")
    check_test "BLOM date test ${ind}" "${tstring}" "${tvals[${ind}]}"
done
dates=(18250.5 18251.5 18252.5 18253.5 18254.5 18255.5 18256.5 18257.5 18258.5 18259.5 18260.5 18261.5 18262.5 18263.5 18264.5 18265.5 18266.5 18267.5 18268.5 18269.5 18270.5 18271.5 18272.5 18273.5 18274.5 18275.5 18276.5 18277.5 18278.5 18279.5 18280.5)
tvals=(18500101 18500102 18500103 18500104 18500105 18500106 18500107 18500108 18500109 18500110 18500111 18500112 18500113 18500114 18500115 18500116 18500117 18500118 18500119 18500120 18500121 18500122 18500123 18500124 18500125 18500126 18500127 18500128 18500129 18500130 18500131)
for ind in $(seq 0 $((${#dates[@]} - 1))); do
    tstring=$(convert_time_to_date "${dates[${ind}]}" "1800")
    check_test "BLOM date test $((${ind} + 4))" "${tstring}" "${tvals[${ind}]}"
done
tstring="10:20001227:20001228:20001229:20001230:20001231:20010101:20010102:20010103:20010104:20010105"
lnd_file="${testdir}/lnd_test_file.clm2_0001.h1.2000-12-27-00000.nc"
dates="$(get_lnd_hist_file_info ${lnd_file})"
check_test "CTSM dates test" "${dates}" "${tstring}"
years="$(get_range_year ${dates} ${lnd_file})"
check_test "CTSM year set test" "${years}" "get_range_year: Multiple years found in ${lnd_file}"
tstring="1:185904xx"
lnd_file="NHISTpiaeroxid_f09_tn14_keyClim20201217.clm2.h0.1859-04.nc"
dates="$(get_lnd_hist_file_info ${lnd_file})"
check_test "CTSM dates test" "${dates}" "${tstring}"
years="$(get_range_year ${dates} ${lnd_file})"
check_test "CTSM year set test" "${years}" "1859"
rof_file="${testdir}/rof_test_file.mosart_0001.h0.2000-05.nc"
dates="$(get_rof_hist_file_info ${rof_file})"
check_test "MOSART dates test" "${dates}" "1:200005xx"
years="$(get_range_year ${dates} ${rof_file})"
check_test "MOSART year set test" "${years}" "2000"

## Parse date tests
tyear="2010"
tmonth="06"
tday="13"
dstr="${tyear}${tmonth}${tday}"
year="$(get_year_from_date ${dstr})"
check_test "${dstr} year test" "${year}" "${tyear}"
month="$(get_month_from_date ${dstr})"
check_test "${dstr} month test" "${month}" "${tmonth}"
day="$(get_day_from_date ${dstr})"
check_test "${dstr} day test" "${day}" "${tday}"
tyear="12322"
dstr="${tyear}${tmonth}${tday}"
year="$(get_year_from_date ${dstr})"
check_test "${dstr} year test" "${year}" "${tyear}"
month="$(get_month_from_date ${dstr})"
check_test "${dstr} month test" "${month}" "${tmonth}"
day="$(get_day_from_date ${dstr})"
check_test "${dstr} day test" "${day}" "${tday}"

## Check file range test for YEARLY merge types
tyear="2001"
frames="5:${tyear}0201:${tyear}0301:${tyear}0401:${tyear}0501:${tyear}0601"
year="$(get_range_year ${frames})"
check_test "good range year test" "${year}" "${tyear}"
frames="5:${tyear}0901:${tyear}1001:${tyear}1101:${tyear}1201:$((tyear + 1))0101"
tfile="foo.nc"
year="$(get_range_year ${frames} ${tfile})"
check_test "multi-year range year test" "${year}" "get_range_year: Multiple years found in ${tfile}"

## Check file range test for MONTHLY merge types
tyear="2001"
tmonth="02"
frames="5:${tyear}${tmonth}27:${tyear}${tmonth}28:${tyear}${tmonth}29:${tyear}${tmonth}30:${tyear}${tmonth}31"
month="$(get_range_month ${frames})"
check_test "good range month test" "${month}" "${tyear}:${tmonth}"
frames="5:${tyear}${tmonth}28:${tyear}${tmonth}29:${tyear}${tmonth}30:${tyear}${tmonth}31:${tyear}$(printf "%02d" $((tmonth + 1)))01"
month="$(get_range_month ${frames})"
check_test "multi-month range month test" "${month}" "get_range_month: Multiple months found in file"
frames="2:${tyear}${tmonth}28:$((tyear + 1))${tmonth}28"
month="$(get_range_month ${frames} ${tfile})"
check_test "multi-year range month test" "${month}" "get_range_month: Multiple years found in ${tfile}"

## Check get_file_date for YEARLY merge types
atm_file="${testdir}/atm_test_file.cam_0001.h1.2000-06-13-00000.nc"
tdate="$(get_file_date ${atm_file} atm yearly)"
check_test "atm yearly get_file_date test" "${tdate}" "2000"
tdate="$(get_file_date ${ice_file} ice yearly)"
check_test "ice yearly get_file_date test" "${tdate}" "2000"
lnd_file="${testdir}/lnd_test_file.clm2_0001.h1.2000-12-27-00000.nc"
tdate="$(get_file_date ${lnd_file} lnd yearly)"
check_test "lnd yearly get_file_date test" "${tdate}" "get_range_year: Multiple years found in ${lnd_file}"
tdate="$(get_file_date ${rof_file} rof yearly)"
check_test "rof yearly get_file_date test" "${tdate}" "2000"

## Check get_file_date for MONTHLY merge types
tdate="$(get_file_date ${atm_file} atm monthly)"
check_test "atm monthly get_file_date test" "${tdate}" "2000:06"
tdate="$(get_file_date ${ice_file} ice monthly)"
check_test "ice monthly get_file_date test" "${tdate}" "2000:05"
tdate="$(get_file_date ${lnd_file} lnd monthly)"
check_test "lnd monthly get_file_date test" "${tdate}" "get_range_month: Multiple years found in ${lnd_file}"
tdate="$(get_file_date ${rof_file} rof monthly)"
check_test "rof monthly get_file_date test" "${tdate}" "2000:05"

## Check some invalid inputs
tdate="$(get_file_date ${atm_file} "foo" "yearly")"
check_test "bad component yearly get_file_date test" "${tdate}" "get_file_date: Unrecognized component type, 'foo'"
tdate="$(get_file_date ${atm_file} "atm" "mergeall")"
check_test "unsupported type yearly get_file_date test" "${tdate}" "get_file_date: Unsupported merge type, 'mergeall'"
tdate="$(get_file_date ${atm_file} "atm" "squirrelly")"
check_test "invalid merge type get_file_date test" "${tdate}" "get_file_date: Unrecognized merge type, 'squirrelly'"
tdate="$(get_file_date "frankly_i_donot_exist.nc" "atm" "monthly")"
check_test "no file yearly get_file_date test" "${tdate}" "get_file_date: File does not exist, 'frankly_i_donot_exist.nc'"

echo ""
echo "****************************"
echo "Total tests run: ${NUMTESTS}"
if [ ${NUMFAIL} -gt 0 ]; then
    echo "${NUMFAIL} tests FAILed"
else
    echo "All tests PASSed"
fi
