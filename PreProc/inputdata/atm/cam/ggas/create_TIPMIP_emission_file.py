import numpy as np
import sys
import xarray as xr
from scipy.io import netcdf
import pandas as pd


# load grgid area from fx
dataset = xr.open_dataset('/mnt/bgcdata-ns2980k/ffr043/TipESM/data/NorESM2-LM/1pctCO2/fx/areacella_fx_NorESM2-LM_1pctCO2_r1i1p1f1_gn.nc')
areavar = dataset['areacella']

# load example emission file
inpath = '/mnt/bgcdata-ns2980k/ffr043/TipESM/data'
dataset = xr.open_mfdataset(inpath+'/emissions-cmip6_CO2_anthro_surface_175001-201512_fv_1.9x2.5_c20181011.nc', decode_times=False, format="NETCDF3_64BIT")
co2var = dataset['CO2_flux']

# calculate emissions based on TCRE (Arora et al., 2020)
TCRE = 1.32 #°C EgC-1
E = 1000 * 0.02 / TCRE #GtC yr-1
Edata =  np.ones((250*12, 1)) * E

# distribute emissions over time and space
# translated to python from matlab based on script by J. Schwinger
nyears = 250
nmonth = nyears * 12
nlon = 144
nlat = 96
start_year=1
time_bnds = np.zeros((2, nmonth))
time = np.zeros(nmonth)
date = np.zeros(nmonth, dtype=np.int32)
co2flx = np.zeros((nmonth, nlat, nlon))
dayim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
days = np.cumsum([0] + dayim[:-1]) + 1
daye = np.cumsum(dayim)

# (assumed) midpoint of each month in the format MMDD
date_mint = [116, 215, 316, 416, 516, 616, 716, 816, 916, 1016, 1116, 1216]
for iy in range(1, nyears + 1):
    for im in range(1, 13):
        idx = (iy - 1) * 12 + im - 1
        time_bnds[0, idx] = 365 * (iy - 1) + days[im - 1] - 1
        time_bnds[1, idx] = 365 * (iy - 1) + daye[im - 1]
        time[idx] = np.sum(time_bnds[:, idx]) / 2.0
        date[idx] = (1850 + (iy - 1)) * 10000 + date_mint[im - 1]

        if start_year <= iy < start_year + 250:
            # unit correction - time
            dt = (time_bnds[1, idx] - time_bnds[0, idx]) * 86400.0
            # Spatially, emissions are distributed evenly over the sphere and months
            totarea = areavar.sum().values
            # unit correction - Gt C to kg CO2
            co2flx[idx, :, :] = Edata[idx - (start_year - 1) *12] * 1e12 * 3.664 / dt / totarea / 12
        else:
            co2flx[idx, :, :] = 0.0


# write emissions to example dataset
dataset = dataset.isel(time=slice(0,3000))
dataset['CO2_flux'].values = co2flx

# assign attributes
dataset = dataset.assign_attrs({'data_title':'Annual Anthropogenic Emissions of CO2 based on TCRE prepared for TIPMIP'})
dataset = dataset.assign_attrs({'data_creator':'F. Froeb (friederike.frob@uib.no)'})
dataset = dataset.assign_attrs({'creation_date':'2024-08-03'})

#set encoding for netcdf file
encoding = {
'time':{'_FillValue': None},
'time_bnds':{'_FillValue': None},
'lon':{'zlib': True, 'shuffle': False, 'complevel': 1, 'fletcher32': False, 'contiguous': False, 
     'dtype': 'float64', '_FillValue':None},
'lat':{'zlib': True, 'shuffle': False, 'complevel': 1, 'fletcher32': False, 'contiguous': False, 
     'dtype': 'float64', '_FillValue':None},
'CO2_flux':{'zlib': True, 'shuffle': True, 'complevel': 9, 'fletcher32': False, 'contiguous': False,
     'dtype': 'float32', 'missing_value': 1e+20, '_FillValue': 1e+20}
}

#write netcdf
dataset.to_netcdf('/mnt/bgcdata-ns2980k/ffr043/TipESM/data/emissions-ESM-tipmip_CO2_anthro_surface_185001-209912_fv_1.9x2.5_c20240803.nc', mode="w", format="NETCDF3_64BIT", encoding=encoding, unlimited_dims='time')



