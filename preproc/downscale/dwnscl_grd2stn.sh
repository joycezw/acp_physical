#!/bin/bash

# downscale monthly averages anomalies of 
# precipitation and average temperature 
# to GHCN station level

# location of NCL
ncl=/usr/local/ncl-6.3.0/bin/ncl

# location of concatenated historical+projected BCSD files
root=/home/dmr/jnk

normals=./normals # location of monthly climate normals
daily=./station_data # location of daily hybrid observation/reanalysis dataset

rm ncl.log

NSET=1 # number of weather realizations (must be <= 20)
for RCP in "rcp26" "rcp45" "rcp60" "rcp85"; do
for VAR in "tas" "pr" "tasmin" "tasmax"; do

fils=`ls $root/merged/*/${RCP}/${VAR}/*195001-*.nc 2>/dev/null`

if [ ${#fils[@]} -eq 0 ]; then continue; fi

for FIL in ${fils[@]}; do

MOD=`echo $FIL | rev | cut -d'/' -f4 | rev`

#if [ ! -z `ls /home/dmr/jnk/smme/001/${RCP}/${MOD}/${VAR}/smme_ghcnd_daily_001_${VAR}_${MOD}_${RCP}_19810101-*.nc 2>/dev/null` ]; then continue ; fi

echo "Working with [ RCP: $RCP ] [ Model: $MOD ] [ Variable: $VAR ] ..."

cat > dwnscl_grd2stn.ncl.tmp << EOF
; dwnscl_grd2stn.ncl

; DJ Rasmussen, last updated: Tue Dec 22 10:07:15 2015

; Temporally downscale monthly means to daily means using
; historical weather variability from a hybrid observation/
; reanalysis dataset 

; The input are gridded projections. The downscaling is 
; at the GHCN station level. Input are anomalies.

; For each climate month in the CMIP5 forecast period 
; one year from the obs. climatology is randomly 
; selected. For each GHCN site, the obs. daily values
; for the year and month selected are scaled so that 
; the monthly averages are equal to the forcasted values for 
; the specific month.

; References:

; Wood et al., Long-range experimental hydrologic forecasting 
; for the eastern United States. JGR - Atmos. 2002

; Rasmussen and co-authors, Probability-weighted ensembles of
; U.S. county-level climate projections for climate risk 
; analysis. J. Appl. Met. Clim. 2016

load "$NCARG_ROOT/lib/ncarg/nclscripts/csm/contributed.ncl"   
load "utils.ncl"   

begin

; require external Fortran code for downscaling temperature
; and precipitation

external DOWNSCALE "./f90/ds.so"

mday = (/31,28.25,31,30,31,30,31,31,30,31,30,31/)
month_abbr = (/"","Jan","Feb","Mar","Apr","May","Jun", \
               "Jul","Aug","Sep","Oct","Nov","Dec"/)

;obs data use standard calendar with leap days
option = 1
option@calendar = "standard"

; First year of downscaled daily projections
yr1 = 1981

; Random weather realizations (must be less than 20)
do iset = 1, $NSET

   ; for each month, randomly select a year from the daily climatology 
   rlines = asciiread("random_years_198101-210012.csv",-1,"string")
   delim = ","
   randyrs = toint(str_get_field(rlines(:),iset+1,delim))
 
   ; get list of normals and GHCN sites to process (no Alaska or Hawaii)
   norm_fil = "${normals}/ghcnd_${VAR}_month_normals_198101-201012.csv"
   print("Opening average monthly station normals: "+norm_fil)
   lines = asciiread(norm_fil,-1,"string")

   stn_code_all = str_get_field(lines,1,delim)
   stn_code_all!0 = "station"
   stn_code_all@_FillValue = "missing"
   stn_code_all@long_name = "GHCN site codes"
   nstation = dimsizes(stn_code_all)
 
   stn_state_all = str_get_field(lines,5,delim)
   stn_state_all!0 = "station"
   stn_state_all@_FillValue = "missing"
   stn_state_all@long_name = "GHCN site name"

   stn_name_all = str_get_field(lines,6,delim)
   stn_name_all!0 = "station"
   stn_name_all@_FillValue = "missing"
   stn_name_all@long_name = "GHCN site state"

   stn_lat = tofloat(str_get_field(lines,2,delim))
   stn_lat!0 = "station"
   stn_lat@_FillValue = -999.99
   stn_lat@units = "degrees_north"
   stn_lat@long_name = "lat"
   stn_lon = tofloat(str_get_field(lines,3,delim))
   stn_lon!0 = "station"
   stn_lon@_FillValue = -999.99
   stn_lon@units = "degrees_east"
   stn_lon@long_name = "lon"
 
   ; convert GHCN normal units
   stn_norm = new((/12,dimsizes(lines)/),"float",-999.999)
   do im=0, 11
    if "${VAR}" .eq. "pr" then
      ; Precip projections are avg. daily precip totals while GHCN normals are monthly totals, so
      ; we need to divide the normal monthly precip totals by the number of days in each month
      stn_norm(im,:) = tofloat(str_get_field(lines(:),7+im,delim))*25.4/mday(im) ; inches to mm
    else
      stn_norm(im,:) = tofloat(str_get_field(lines(:),7+im,delim)) + 273.15
    end if
   end do
   delete(lines)

   print("Opening gridded monthly downscaled GCM projections: ${FIL}")
   grid_fil = addfile("${FIL}","r")
   var_grid = grid_fil->${VAR} ; (time, lat, lon)
   lat_grid  = grid_fil->lat
   lon_grid  = grid_fil->lon
   time_mon = grid_fil->time
   ntim_grid = dimsizes(time_mon)


   ; Open daily observational-reanalysis combined historical station data 
   daily_filname = "${daily}/ghcnd_station_${VAR}_daily_19810101-20101231.nc"
   print("Opening daily observational-reanalysis combined historical station data: "+daily_filname)
   dfil = addfile(daily_filname,"r")
   stn_daily_all = dfil->${VAR} ; (time,station)
   stn_time = dfil->time ; daily

   utc_date = cd_calendar(time_mon(dimsizes(time_mon)-1), 0) ; get the last year in time record
   yr2 = tointeger(utc_date(:,0))
   dd = tointeger(utc_date(:,2))
   hh = tointeger(utc_date(:,3))
   option = 1
   option@calendar = time_mon@calendar
 
   yyyymm = yyyymm_time(yr1,yr2,"integer")
   months = yyyymm - (yyyymm/100)*100

   floc = cd_inv_calendar(yr1,1,dd,hh,0,0,time_mon@units,option)
   ist = closest_val(floc,time_mon) ; start point for downscaling

   stn_daily_temp = new((/dimsizes(stn_time),nstation/),"float",-999.99)
   stn_daily_temp!0 = "time"
   stn_daily_temp!1 = "station"
   stn_daily_temp&time = stn_time

   stn_code_temp = new((/nstation/),"string")
   stn_code_temp!0 = "station"
   stn_state_temp = new((/nstation/),"string")
   stn_state_temp!0 = "station"
   stn_name_temp = new((/nstation/),"string")
   stn_name_temp!0 = "station"
 
   lat_temp = new((/nstation/),"float",-999.99)
   lat_temp!0 = "station"
   lon_temp = new((/nstation/),"float",-999.99)
   lon_temp!0 = "station"

   ; Map GCM gridcells to GHCN stations
   model_month_temp = new((/ntim_grid-ist,nstation/),"float",-999.99)
   model_month_temp!0 = "time"
   model_month_temp!1 = "station"
   if "${VAR}" .eq. "pr" then
    model_month_temp@units = "mm"
    model_month_temp@long_name = "monthly avg. daily precipitation (liquid equivalent)"
   else
    model_month_temp@units = "degrees K"
    model_month_temp@long_name = "daily average temperature"
   end if
   model_month_temp@_FillValue = -999.999
   model_month_temp@comment = "monthly model projection anomaly plus monthly normal"
   
   ; 2d lat/lon for GCM-GHCN Station Mapping
   lat2d = new((/dimsizes(lat_grid),dimsizes(lon_grid)/),"float",-999.999)
   lon2d = new((/dimsizes(lat_grid),dimsizes(lon_grid)/),"float",-999.999)
   do i=0,dimsizes(lon_grid)-1
    lat2d(:,i) = lat_grid
   end do
   do i=0,dimsizes(lat_grid)-1
    lon2d(i,:) = lon_grid
   end do


   ; Map GHCN stations to counties and GCM grid cells to county centroids

   ; Before mapping, check to see if BCSD grid cell mapping file already exists
   if fileexists("./${VAR}_conus_bcsd_xy_map.csv") then
    lines = asciiread("./${VAR}_conus_bcsd_xy_map.csv",-1,"string")
    x = toint(str_get_field(lines(1:),3,","))
    y = toint(str_get_field(lines(1:),4,","))
    ii = 0
    do istn=0, nstation-1
      if stn_lon(istn)+360 .gt. 235 then ; no AK or HI
        stn_daily_temp(:,ii) = (/ stn_daily_all(:,istn) /)
        lat_temp(ii) = stn_lat(istn)
        lon_temp(ii) = stn_lon(istn)
        stn_code_temp(ii) = stn_code_all(istn)
        stn_name_temp(ii) = stn_name_all(istn)
        stn_state_temp(ii) = stn_state_all(istn)
        it = 0
        do nt=ist, ntim_grid-1 ; only want monthlies from 1981 onwards...
          ; add monthly station normal to each GCM projection anomaly
          model_month_temp(it,ii) = var_grid(nt,y(ii),x(ii)) + stn_norm(months(it)-1,istn)
          it = it + 1
        end do
        ii = ii + 1
      end if
    end do
    nstn_no_AK_HI = ii
   else
     print("Mapping GHCN stations and model grid cells to county lat/lon centroids...")
     print("")
     x_temp = new((/nstation/),"integer",-999) ; GCM mapping (x,y) to GHCN station
     y_temp = new((/nstation/),"integer",-999)
     ii=0
     do istn=0, nstation-1
      if stn_lon(istn)+360 .gt. 235 then ; no AK or HI
         ; determine model lat and lon indices of GHCN station
         ij = getind_closest_latlon2d(lat2d,lon2d,stn_lat(istn),stn_lon(istn)+360,var_grid(0,:,:),stn_name_all(istn),stn_state_all(istn)) 
         print((ii+1)+" Mapping GCM grid cell: ("+ij(0)+","+ij(1)+") to GHCN station: "+ \
                                              stn_name_all(istn)+", "+stn_state_all(istn))
         x_temp(ii) = ij(1)
         y_temp(ii) = ij(0)
         ; select only non-Alaska and Hawaii stations
         stn_daily_temp(:,ii) = (/ stn_daily_all(:,istn) /)
         lat_temp(ii) = stn_lat(istn)
         lon_temp(ii) = stn_lon(istn)
         stn_code_temp(ii) = stn_code_all(istn)
         stn_name_temp(ii) = stn_name_all(istn)
         stn_state_temp(ii) = stn_state_all(istn)
         ; select only the time period of interest
         it = 0
         do nt=ist, ntim_grid-1 ; only want monthlies from 1981 onwards...
           ; add monthly station normal to each GCM projection anomaly
           model_month_temp(it,ii) = var_grid(nt,ij(0),ij(1)) + stn_norm(months(it)-1,istn)
           it = it + 1
         end do
         ii = ii + 1
      end if ; if site is not Alaska or Hawaii
     end do ;  all stations

     nstn_no_AK_HI = ii

     x = x_temp(0:nstn_no_AK_HI-1)
     y = y_temp(0:nstn_no_AK_HI-1)

     ; write table to text file
     txtFil = "${VAR}_conus_bcsd_xy_map.csv"
     print("Writing text file: "+txtFil)
     asciiwrite(txtFil,"x,y")
     write_table(txtFil,"a",[/stn_code_temp(0:nstn_no_AK_HI-1), \
                       stn_state_temp(0:nstn_no_AK_HI-1),x,y/], \
         "%s,%s,%3i,%3i")
     print("")
   end if

   print("")

   ; reshape arrays
   stn_daily = stn_daily_temp(:,0:nstn_no_AK_HI-1)
   stn_code = stn_code_temp(0:nstn_no_AK_HI-1)
   stn_name = stn_name_temp(0:nstn_no_AK_HI-1)
   stn_state = stn_state_temp(0:nstn_no_AK_HI-1)
   model_month = model_month_temp(:,0:nstn_no_AK_HI-1)
   lat = lat_temp(0:nstn_no_AK_HI-1)
   lon = lon_temp(0:nstn_no_AK_HI-1)
 
   ; calculate monthly means from daily
   print("Calculating monthly means from daily...")
   stn_month = calculate_monthly_values(stn_daily, "avg", 0, False); includes leap days

   ; create new daily time record
   xtime = new((/((yr2-yr1)+1)*365/),"double")
   xtime!0 = "time"
   option = 1
   option@calendar = "noleap"
 
   ; create out array
   xarr = new((/dimsizes(xtime),nstn_no_AK_HI/),"float",-999.99)
   xarr!0 = "time"
   xarr!1 = "station"
   xarr@_FillValue = -999.99
   if "${VAR}" .ne. "pr" then
    xarr@units = "K"
    xarr@long_name = "Daily temperature projections at GHCN stations"
   else
    xarr@units = "mm"
    xarr@long_name = "Daily precip projections at GHCN stations"
   end if
   xarr&time = xtime

   ; Downscale monthly to daily
   icount = 0 ; month counter
   iday = 0 ; day counter
   do iy=0, (yr2-yr1)
    do im=1, 12

      rndyr = randyrs(icount)
      print("")

      last_day = days_in_month(2001, im) ; force non-leap calendar to skip leap days
      print("Downscaling monthly ${VAR} averages to daily averages using random year: " +rndyr+ " ...")

      ; get location of first and last day in this month in the time record of "stn_daily"
      option = 1
      option@calendar = "standard"
      datum_grd = time_mon@units
      datum_stn = "days since 1950-01-01 00:00:00"

      floc = cd_inv_calendar(rndyr,im,1,12,0,0,datum_stn,option) ; standard calendar
      is = ind(stn_time.eq.floc)
      floc = cd_inv_calendar(rndyr,im,last_day,12,0,0,datum_stn,option)
      ie = ind(stn_time.eq.floc)
 
      if ("${VAR}" .eq. "pr" ) then

        fct = new((/nstn_no_AK_HI/),"float",-999.99)
        this_mon = stn_month(((12*(rndyr-1981))+im)-1,:)
 
        ; normalize all daily values to CMIP5 monthly means
        denom = where(this_mon.eq.0,stn_month@_FillValue,this_mon)
        fct = model_month(icount,:)/ denom
        fct = where(fct.lt.0,0,fct) ; replace negative values with zero
        print("Max daily scaling factor is: " + max(fct) + " | Min daily scaling factor is: " + min(fct))

        ; temporary array to pass to the Fortran routine
        nday = ie-is+1 ; days in current month
        xday = new((/nday,nstn_no_AK_HI/), "float", -999.99)
        xday!0 = "day"
        xday!1 = "station"
 
        icnt = 0 ; count spillovers
        iscnt = 0 
        DOWNSCALE::ds(nstn_no_AK_HI,last_day,stn_daily(station|:,time|is:ie), \
                             fct,model_month(icount,:),xday(station|:,day|0:last_day-1),icnt,iscnt,True)
        xarr(iday:iday+nday-1,:) = (/xday/)

        delete(xday)
        print("Daily precipitation rate across all stations for "+month_abbr(im)+" "+ \
          sprinti("%0.4i", iy + yr1)+": Max: "  +max(xarr(iday:iday:nday-1,:))+" mm/d "+ \ 
                                     "  Min: "+min(xarr(iday:iday+nday-1,:))+" mm/d")
        print("Precipitation spillover performed for "+icnt+" days and "+iscnt+" stations... ")
        ; create out time data
        option = 1 ; no leap for output
        option@calendar = "noleap"
        
        do imonth_day = 1, last_day
          xtime(iday) = cd_inv_calendar(iy + yr1,im,imonth_day,12,0,0,datum_grd,option)
          iday = iday + 1
        end do
      else ; downscale temperature

        ; dummy variables that do nothing when downscaling temperature
        icnt = 0
        iscnt = 0

        nday = ie-is+1 ; days in current month

        DOWNSCALE::ds(nstn_no_AK_HI,last_day,stn_daily(station|:,time|is:ie),stn_month(((12*(rndyr-1981))+im)-1,:), \
                             model_month(icount,:),xarr(station|:,time|iday:iday+nday-1),icnt,iscnt,False)

        do imonth_day = 1, last_day
          xtime(iday) = cd_inv_calendar(iy + yr1,im,imonth_day,12,0,0,datum_grd,option)
          iday = iday + 1
        end do

        ; debug only
        ;  date_str = sprinti("%0.2i", imonth_day) + " " + month_abbr(im) + " "  + sprinti("%0.4i", iy+2000)
        ;  print("Created data for: "+date_str)
        ; debug only

      end if

    ; as a QA/QC, calculate monthly average from dailies to see if they match the monthly averages
      floc = cd_inv_calendar(iy + yr1,im,1,12,0,0,datum_grd,option) ; no leap
      is = ind(xtime.eq.floc)
      floc = cd_inv_calendar(iy + yr1,im,last_day,12,0,0,datum_grd,option)
      ie = ind(xtime.eq.floc)
      print("Sample Site: "+stn_name(3)+", "+stn_state(3)+" | Downscaling ... "+month_abbr(im)+" "+ sprinti("%0.4i", iy+yr1)+"...")
      print("Downscaled monthly mean (from dailies): "+dim_avg_n(xarr(is:ie,3),0)+" "+xarr@units+" | ${MOD^^} monthly mean: "+model_month(icount,3)+" "+xarr@units)

    icount = icount + 1
    end do; month
   end do; year
 
   ; QA data before writing to disk
   if "${VAR}" .eq. "pr" then
      ltz_check = True ; "less than zero" check
   else
      ltz_check = False ; "less than zero" check
   end if
   
   ; Check for values missing in arrays
   if any(ismissing(xarr)) then
    xarr_1d = ndtooned(xarr)
    dsizes = dimsizes(xarr)
    indices  = ind_resolve(ind(ismissing(xarr_1d)),dsizes)
    ncells = dimsizes(indices)
    do ii=0, ncells(0)-1
      print(" FOUND MISSING! x: " +indices(ii,0)+" y: "+indices(ii,1))
    end do
    printVarSummary(xarr)
    exit
   end if
   
   ; Check for values less than zero
   lcheck = QA_ndarray(xarr,ltz_check)
   if lcheck then
    print("Problems! marker1")
    exit
   end if
   
   ; write out netCDF file
   ncDir = "${root}/smme/"+sprinti("%0.3i", iset)+"/${RCP}/${MOD}/${VAR}"
   system("if ! test -d " + ncDir +" ; then mkdir -p " + ncDir + " ; fi")
   ncFil = "smme_ghcnd_daily_"+sprinti("%0.3i", iset)+"_${VAR}_${MOD}_${RCP}_"+yr1+"0101-"+yr2+"1231.nc"
   NCFILE = ncDir + "/" +ncFil
   
   print("")
   print("Writing: " +NCFILE)
   setfileoption("nc","Format","NetCDF4") ; explicitly start file definition mode.
   ncdf = addfile(NCFILE,"c")
   
   globAtt = True
   globAtt@Conventions = "None"
   globAtt@frequency = "daily"
   globAtt@creation_date = systemfunc ( "date" )
   fileattdef( ncdf, globAtt) ; update attributes
   
   ;   predefine the coordinate variables
   dimNames = (/"time","station"/)
   dimSizes = (/-1,nstn_no_AK_HI/)
   dimUnlim = (/True,False/)
   filedimdef( ncdf,dimNames,dimSizes,dimUnlim) ; make time UNLIMITED dimension
   
   filevardef(ncdf,"time",typeof(xtime),getvardims(xtime))
   filevardef(ncdf,"code",typeof(stn_code),getvardims(stn_code))
   filevardef(ncdf,"name",typeof(stn_name),getvardims(stn_name))
   filevardef(ncdf,"state",typeof(stn_state),getvardims(stn_state))
   filevardef(ncdf,"lat",typeof(lat),getvardims(lat))
   filevardef(ncdf,"lon",typeof(lon),getvardims(lon))
   filevardef(ncdf,"${VAR}",typeof(xarr),getvardims(xarr))

   filevarattdef(ncdf,"time",xtime)
   filevarattdef(ncdf,"code",stn_code_all)
   filevarattdef(ncdf,"name",stn_name_all)
   filevarattdef(ncdf,"state",stn_state_all)
   filevarattdef(ncdf,"lat",stn_lat)
   filevarattdef(ncdf,"lon",stn_lon)
   filevarattdef(ncdf,"${VAR}",xarr)

   varAtt = True
   varAtt@contents = "projections at GHCN stations"
   varAtt@model = "${MOD}"
   varAtt@experiment = "${RCP}"
   varAtt@set = sprinti("%0.3i", iset)
   varAtt@history = "Processed by DJ Rasmussen (Rhodium Group, LLC); email: d.m.rasmussen.jr@gmail.com"
   varAtt@frequency ="daily"
   varAtt@reference = "Method from Wood et al. (2002) (section 2.3.2) from JGR-atmospheres"
   varAtt@actual_range = (/ min(xarr), max(xarr) /)
   varAtt@time = xtime(0)
   filevarattdef(ncdf,"${VAR}",varAtt)
   
   ncdf->time = (/xtime/)
   ncdf->code = (/stn_code/)
   ncdf->name = (/stn_name/)
   ncdf->state = (/stn_state/)
   ncdf->lat = (/lat/)
   ncdf->lon = (/lon/)
   ncdf->${VAR}  =  (/xarr/)
    
   setfileoption(ncdf,"DefineMode",False) ; explicitly exit file definition mode.

 end do; weather realization set

end
EOF

$ncl dwnscl_grd2stn.ncl.tmp | tee ncl.log
rm dwnscl_grd2stn.ncl.tmp

done # each model
done # each variable
done # each scenario
