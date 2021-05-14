# Place to override setting elsewhere, in particular things set in Makefile.linux_x86_64_gfortran
# look in QUIP/arch/Makefile.linux_x86_64_gfortran for defaults set by arch
# 
# F77=gfortran
# F90=gfortran
# F95=gfortran
# CC=gcc
# CPLUSPLUS=g++
# FPP=gfortran -E -x f95-cpp-input
# LINKER=gfortran
# LIBTOOL=
# OPTIM=
# COPTIM=
# DEBUG=-O0 -g -DDUMP_CORE_ON_ABORT -DDEBUG -fbounds-check
# DEBUG=
# CDEBUG=
MATH_LINKOPTS=-llapack -lblas
EXTRA_LINKOPTS=
HAVE_CP2K=0
HAVE_VASP=0
HAVE_TB=0
HAVE_PRECON=0
HAVE_LOTF=0
HAVE_ONIOM=0
HAVE_LOCAL_E_MIX=0
HAVE_QC=0
HAVE_GAP=1
HAVE_QR=0
HAVE_THIRDPARTY=0
HAVE_FX=0
HAVE_SCME=0
HAVE_MTP=0
HAVE_MBD=0
HAVE_TTM_NF=0
HAVE_CH4=0
HAVE_NETCDF4=0
HAVE_MDCORE=0
HAVE_ASAP=0
HAVE_CGAL=0
HAVE_METIS=0
HAVE_LMTO_TBE=0
SIZEOF_FORTRAN_T=2
PIP=pip3
PYTHON=python