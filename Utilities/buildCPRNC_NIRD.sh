#! /bin/bash

## These steps should allow cprnc to be built on NIRD
## Instructions current as of 15/10/20223
##
## 1. Download and cd to source of cprnc
##    a. One source: git clone https://github.com/ESMCI/cprnc
## 2. Copy Macros.make.nird from this directory (cp <here>/Macros.make.cprnc.nird Macros.make)
## 3. Load a compatible set of modules (intel compiler, netCDF-Fortran, PnetCDF)
## 4. Replace placeholders for @@NETCDF_C_PATH@@, @@NETCDF_FORTRAN_PATH@@, and @@PNETCDF_PATH@@
##    with the correct pathnames
## 5. Run make
## 6. Install cprnc executable

CPRNC_VERS="v1.0.6"

## Load modules necessary to build cprnc
module purge
module load CMake/3.23.1-GCCcore-11.3.0
module load NCO/5.0.3-intel-2021b
export NetCDF_C_LIBRARIES=${EBROOTNETCDF}
CMAKE_OPTS="-DCMAKE_C_COMPILER=icc -DCMAKE_CXX_COMPILER=icpc"
CMAKE_OPTS="${CMAKE_OPTS} -DCMAKE_Fortran_COMPILER=ifort"
#CMAKE_OPTS="${CMAKE_OPTS} -DCMAKE_BUILD_TYPE=Debug"

startdir="$( pwd -P )"
scriptdir="$( dirname $( realpath $0 ) )"

perr() {
  ## Report an error and exit if the first argument is not zero
  ## Optional error message in second argument
  if [ $1 -ne 0 ]; then
    if [ $# -gt 1 ]; then
      echo "ERROR ($1): ${2}"
    fi
    exit $1
  fi
}

build_openssl() {
    # Function to build an OpenSSL library that can be used by NetCDF
    git clone https://github.com/openssl/openssl
    cd openssl
    git checkout openssl-3.2.1
}

build_netcdf() {
    # Function should start in a directory where code should be downloaded and built
    local netcdfc_dir="netcdf_c"
    local netcdff_dir="netcdf_fortran"
    if [ -d "${netcdfc_dir}" ]; then
        rm -rf ${netcdfc_dir}
    fi
    git clone http://github.com/Unidata/netcdf-c ${netcdfc_dir}
    cd ${netcdfc_dir}
    git checkout v4.6.3
    mkdir build
    cd build
    cmake -DENABLE_DAP_REMOTE_TESTS=OFF ..
    make
    cd ../..
    if [ -d "${netcdff_dir}" ]; then
        rm -rf ${netcdff_dir}
    fi
    git clone https://github.com/Unidata/netcdf-fortran ${netcdff_dir}
    cd ${netcdff_dir}
    git checkout v4.5.2
    mkdir build
    cd build
    cmake ..
    make
}

## Do we need to clone cprnc?
if [ -d "${startdir}/cprnc" -a -d "${startdir}/cprnc/test_inputs" ]; then
  # We are sitting just above the cprnc directory
  cd ${startdir}/cprnc
  perr $? "trying to cd to cprnc source directory"
elif [ -d "${startdir}/test_inputs" -a -f "${startdir}/CMakeLists.txt" ]; then
  # We are sitting in a cprnc directory
  cd ${startdir}
  perr $? "trying to cd to cprnc local source directory"
else
  # No cprnc around, create one
  cd ${startdir}
  perr $? "trying to cd to starting directory, '${startdir}'"
  git clone https://github.com/ESMCI/cprnc
  perr $? "cloning ESMCI/cprnc"
  cd cprnc
  perr $? "trying to cd to new cprnc clone"
fi

# Make sure we have the correct tag
git checkout ${CPRNC_VERS}
perr $? "trying to checkout ${CPRNC_VERS}"

if [ -d "bld" ]; then
    rm -rf bld/*
    perr $? "trying to clean bld directory"
else
    mkdir bld
    perr $? "trying to mkdir bld directory"
fi
cd bld
perr $? "trying to cd to bld directory"

# CMake!
cmake ${CMAKE_OPTS} ..
perr $? "Trying to run 'cmake ${CMAKE_OPTS} ..'"

# Make!
make
perr $? "trying to make cprnc"
# Finally, move make to starting directory
mv cprnc ${startdir}
perr $? "moving cprnc to starting directory"
