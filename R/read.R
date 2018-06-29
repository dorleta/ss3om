# readSS3.R - DESC
# ioalbmse/R/readSS3.R

# Copyright European Union, 2015-2017
# Author: Iago Mosqueira (EC JRC) <iago.mosqueira@ec.europa.eu>
#
# Distributed under the terms of the European Union Public Licence (EUPL) V.1.1.

# readFLBFss3 {{{

readFLBFss3 <- function(dir, birthseas=unique(out$natage$BirthSeas), ...) {

  # LOAD SS_output list
  out <- r4ss::SS_output(dir, verbose=FALSE, hidewarn=TRUE, warn=FALSE,
    printstats=FALSE, covar=TRUE, forecast=FALSE, ...)

  # TODO CHECK out has needed elements

  out <- out[c("catage", "wtatage", "natage", "ageselex", "endgrowth",
    "catch_units", "nsexes", "nseasons", "nareas", "IsFishFleet", "fleet_ID",
    "FleetNames", "timeseries", "parameters")]

  # GET range
  range <- getRange(out$catage)
  ages <- ac(seq(range['min'], range['max']))

  # GET dimnames
  dmns <- list(age=ages,
    year=seq(range['minyear'], range['maxyear']),
    # unit = combinations(Sex, birthseas)
    unit=c(t(outer(switch(out$nsexes, "", c("F", "M")),
    switch(length(birthseas), "", birthseas), paste0))),
    season=seq(out$nseasons),
    area=seq(out$nareas),
    iter=1)

  # --- BIOL (endgrowth, natage)

  # EXTRACT endgrowth
  endgrowth <- data.table(out$endgrowth, key=c("Seas", "Sex", "BirthSeas", "Age"))

  # -- STOCK.WT
  
  # EXTRACT stock.wt - endgrowth[, Seas, BirthSeas, Age, M]
  wt <- endgrowth[BirthSeas %in% birthseas,
    list(BirthSeas, Sex, Seas, Age, Wt_Beg)]

  # CREATE unit from Sex + BirthSeas
  wt[, unit:=paste0(ifelse(Sex == 1, "F", "M"),
    ifelse(length(birthseas) == 1, "", BirthSeas)),]

  # RENAME
	names(wt) <- c("BirthSeas", "Sex", "season", "age", "data", "unit")

  # EXPAND by year, unit & season
  wt <- FLCore::expand(as.FLQuant(wt[, .(season, age, data, unit)],
    units="kg"), year=dmns$year, unit=dmns$unit, season=dmns$season)

  # -- MAT

  # EXTRACT mat - endgrowth
  # NOTE that only Gender 1 (F) is used, M is all -1
  mat <- endgrowth[BirthSeas %in% birthseas & Sex == 1,
    list(BirthSeas, Sex, Seas, Age, Age_Mat)]

  # RENAME
  names(mat) <- c("BirthSeas", "unit", "season", "age", "data")

  # EXPAND by year & unit
  mat <- FLCore::expand(as.FLQuant(mat[, .(season, age, data)],
    units="NA"), year=dmns$year, unit=dmns$unit)

  mat <- predictModel(mat=mat, model=~mat)

  # -- M
  
  # EXTRACT m - biol[, Seas, BirthSeas, Age, M]
  m <- endgrowth[BirthSeas %in% birthseas,
    list(BirthSeas, Sex, Seas, Age, M)]

  # CREATE unit from Gender + BirthSeas
  m[, unit:=paste0(ifelse(Sex == 1, "F", "M"),
    ifelse(length(birthseas) == 1, "", BirthSeas)),]

  # RENAME
	names(m) <- c("BirthSeas", "Sex", "season", "age", "data", "unit")
  
  # EXPAND by year, unit & season
  m <- FLCore::expand(as.FLQuant(m[,.(season, age, data, unit)], units="m"),
    year=dmns$year, unit=dmns$unit, season=dmns$season)

  # -- N

  n <- data.table(out$natage)
  
  # SELECT start of season (Beg/Mid == 'B'), Era == 'TIME' & cols
  n <- n[`Beg/Mid` == "B" & Era == 'TIME',
    .SD, .SDcols = c("Sex", "BirthSeas", "Yr", "Seas", ages)]

  # MELT by Gender, BirthSeas, Yr & Seas
  # BUG: BirthSeason should turn at some point to BirthSeas
	n <- data.table::melt(n, id.vars=c("Sex", "BirthSeas","Yr","Seas"),
    variable.name="age")
  
  # SUBSET according to birthseas
  n <- n[BirthSeas %in% birthseas, ]

  # CREATE unit from Gender + BirthSeas
  n[, unit:=paste0(ifelse(Sex == 1, "F", "M"),
    ifelse(length(birthseas) == 1, "", BirthSeas)),]
  
  # DROP Gender and BirthSeas
  n[, c("Sex","BirthSeas") := NULL]

  # RENAME
  names(n) <- c("year", "season", "age", "data", "unit")

  n <- as.FLQuant(n, units="1000")

  # REC
  rec <- predictModel(model=~(4 * h * R0 * unitSums(ssb)) / (B0 * (1 - h) +
    unitSums(ssb) * (5 * h -1)), params=FLPar(h=out$parameters["SR_BH_steep","Value"],
    B0=sum(out$timeseries$SpawnBio[out$timeseries$Era=="VIRG"], na.rm=TRUE),
    R0=sum(out$timeseries$Recruit_0[out$timeseries$Era=="VIRG"], na.rm=TRUE)))

  # -- FLBiol

  biol <- FLBiol(n=n, wt=wt, m=m, mat=mat, rec=rec)
  
  # -- SPWN
  spwn(biol)[,,,birthseas] <- 0.5

  # BUG FLBiol dimensions, FLQs & FLPs

  # -- FISHERIES (catage, wtatage, ageselex)

  # CAA, WAA, SEL
  catage <- data.table(out$catage,
    key=c("Area", "Fleet", "Gender", "Morph", "Yr", "Seas", "Era"))
  wtatage <- data.table(out$wtatage,
    key=c("Yr", "Seas", "Sex", "BirthSeas", "Fleet"))
  ageselex <- data.table(out$ageselex,
    key=c("Factor", "Fleet", "Yr", "Seas", "Sex", "Morph"))[Factor == "Asel2",]

  # BUG: Yr in wtatage is negative
  wtatage[, Yr:=abs(Yr)]

  # RECONSTRUCT BirthSeas from Morph & Gender
  catage[, BirthSeas := Morph - (max(Seas) * (Gender - 1))]
  ageselex[, BirthSeas := Morph - (max(Seas) * (Sex - 1))]
  
  # FIND and SUBSET fishing fleets, TIME and BirthSeas
  idx <- out$fleet_ID[out$IsFishFleet]
  catage <- catage[Fleet %in% idx & Era == "TIME" & BirthSeas %in% birthseas,]
  # BUG: scoping does not allow [ on variable with name matching column name
  ref <- birthseas
  wtatage <- wtatage[Fleet %in% idx & BirthSeas %in% ref,]
  ageselex <- ageselex[Yr >= min(catage[, Yr]) & Yr <= max(catage[, Yr]) &
    BirthSeas %in% birthseas,]

  # CREATE unit from Gender + BirthSeas
  catage[, unit:=paste0(ifelse(Gender == 1, "F", "M"),
    ifelse(length(birthseas) == 1, "", BirthSeas)),]
  wtatage[, unit:=paste0(ifelse(Sex == 1, "F", "M"),
    ifelse(length(ref) == 1, "", BirthSeas)),]
  ageselex[, unit:=paste0(ifelse(Sex == 1, "F", "M"),
    ifelse(length(ref) == 1, "", BirthSeas)),]

  # MELT by Gender, BirthSeas, Yr & Seas
	catage <- data.table::melt(catage, id.vars=c("Area", "Fleet", "Yr", "Seas", "unit"),
    measure.vars=ages, variable.name="age")
  names(catage) <- c("area", "fleet", "year", "season", "unit", "age", "data")

  wtatage <- data.table::melt(wtatage, id.vars=c("Yr", "Seas", "Fleet", "unit"),
    measure.vars=ages, variable.name="age")
  names(wtatage) <- c("year", "season", "fleet", "unit", "age", "data")

	ageselex <- data.table::melt(ageselex, id.vars=c("Fleet", "Yr", "Seas", "unit"),
    measure.vars=ages, variable.name="age")
  names(ageselex) <- c("fleet", "year", "season", "unit", "age", "data")

  # CATCHES
  catches <- lapply(idx, function(x) {

    landings.n <- as.FLQuant(catage[fleet %in% x,][, fleet:=NULL], units="1")
    landings.wt <- as.FLQuant(wtatage[fleet %in% x,][, fleet:=NULL], units="kg")
    # catch.sel <- predictModel(model=~catch.sel,
    #   FLQuants(catch.sel=as.FLQuant(ageselex[fleet %in% x,][, fleet:=NULL], units="NA")))
    catch.sel <- as.FLQuant(ageselex[fleet %in% x,][, fleet:=NULL], units="NA")
  
    # CORRECT landings.n in biomass to numbers (catch_units)
    if(out$catch_units[x] == 1) {
      landings.n <- landings.n / landings.wt
      units(landings.n) <- "1"
    }

    res <- FLCatch(name="ALB", landings.n=landings.n, landings.wt=landings.wt,
      catch.sel=catch.sel)

    # discards
    discards.n(res)[] <- 0
    discards.wt(res) <- landings.wt(res)

    return(res)
    }
  )

  # capacity
  # effort
  # hperiod

  # CREATE fisheries
  fisheries <- FLFisheries(lapply(catches,
    function(x) {

      fi <- FLFishery(ALB=x)

      return(fi)
    }
  ))

  # NAME as in out$FleetNames
  names(fisheries) <- out$FleetNames[idx]

  return(list(biol=biol, fisheries=fisheries))

} # }}}

# readFLSss3 {{{

#' A function to read SS3 results as an FLStock object
#'
#' Results of a run of the Stock Synthesis sofware, SS3 (Methot & Wetzel, 2013),
#' can be loaded into an object of class \code{\link{FLStock}}. The code makes
#' use of the r4ss::SS_output function to obtain a list from Report.sso. The
#' following elements of that list are used to generate the necessary information
#' for the slots in \code{\link{FLStock}}: "catage", "natage", "ageselex",
#' "endgrowth", "catch_units", "nsexes", "nseasons", "nareas", "IsFishFleet",
#' "fleet_ID", "FleetNames", "spawnseas", "inputs" and "SS_version".
#'
#' @references
#' Methot RD Jr, Wetzel CR (2013) Stock Synthesis: A biological and statistical
#' framework for fish stock assessment and fishery management.
#' Fisheries Research 142: 86-99.
#'
#' @param dir Directory holding the SS3 output files
#' @param birthseas Birth seasons for this stock, defaults to spawnseas
#' @param name Name of the output object to fil the name slot
#' @param desc Description of the output object to fill the desc slot
#' @param ... Any other argument to be passed to `r4ss::SS_output`
#'
#' @return An object of class `\link{FLStock}`
#'
#' @name readFLSss3
#' @rdname readFLSss3
#' @aliases readFLSss3
#'
#' @author The FLR Team
#' @seealso \link{FLComp}
#' @keywords classes

readFLSss3 <- function(dir, birthseas=out$birthseas, name="ss3",
  desc=paste(out$inputs$repfile, out$SS_version, sep=" - "), ...) {

  # LOAD SS_output list
  out <- r4ss::SS_output(dir, verbose=FALSE, hidewarn=TRUE, warn=FALSE,
    printstats=FALSE, covar=FALSE, forecast=FALSE, ...)
  
  # SUBSET out
  out <- out[c("catage", "natage", "ageselex", "endgrowth",
    "catch_units", "nsexes", "nseasons", "nareas", "IsFishFleet", "fleet_ID",
    "FleetNames", "birthseas", "spawnseas", "inputs", "SS_version")]

  # GET range from catage
  range <- getRange(out$catage)
  ages <- ac(seq(range['min'], range['max']))
  idx <- out$fleet_ID[out$IsFishFleet]

  dmns <- getDimnames(out, birthseas=birthseas)
  dim <- unlist(lapply(dmns, length))

  # EXTRACT from out
  if(out$nsexes == 1) {
    endgrowth <- data.table(out$endgrowth, key=c("Seas", "BirthSeas", "Age"))
  } else {
    endgrowth <- data.table(out$endgrowth, key=c("Seas", "Sex", "BirthSeas", "Age"))
  }

  # NATAGE
  natage <- data.table(out$natage)
  
  # CATCH.N
  catage <- data.table(out$catage)
  setkey(catage, "Area", "Fleet", "Gender", "Morph", "Yr", "Seas", "Era")

  # STOCK.WT
  wt <- ss3wt(endgrowth, dmns, birthseas)

  # MAT
  mat <- ss3mat(endgrowth, dmns, birthseas)

  # M
  m <- ss3m(endgrowth, dmns, birthseas)
  
  # STOCK.N
  n <- ss3n(natage, dmns, birthseas)

  # CATCH.WT, assumes _mat_option == 3
  wtatage <- endgrowth[BirthSeas %in% birthseas,
    c("Seas", "Sex", "BirthSeas", "Age", paste0("RetWt:_", idx)), with=FALSE]

  landings <- ss3catch(catage, wtatage, dmns, birthseas, idx)
  
  # CALCULATE total landings.n
  landings.n <- FLQuant(0, dimnames=dmns, units="1000")
  for (i in seq(length(idx)))
    landings.n <- landings.n %++% landings[[i]]$landings.n
  
  # AVERAGE landings.wt weighted by landings.n
  landings.wt <-  FLCore::expand(Reduce("+", lapply(landings,
    function(x) x$landings.n %*% x$landings.wt)) %/% landings.n,
    year=dmns$year, area=dmns$area)
  
  # EXPAND m and mat by area
  # m <- do.call(FLCore::expand, c(list(x=m), dmns))
  # mat <- do.call(FLCore::expand, c(list(x=mat), dmns))
  
  # FLStock
  stock <- FLStock(
    name=name, desc=desc,
    landings.n=landings.n, landings.wt=landings.wt,
    stock.n=n, stock.wt=wt,
    m=m, mat=mat)

  # CALCULATE stock, catch, landings & discards
  discards.n(stock) <- 0
  units(discards.n(stock)) <- units(landings.n(stock))
  discards.wt(stock) <- landings.wt(stock)

  landings(stock) <- computeLandings(stock)
  discards(stock) <- computeDiscards(stock)
  catch(stock) <- computeCatch(stock, slot='all')
  stock(stock) <- computeStock(stock)

  # ASSIGN harvest.spwn and m.spwn in birthseas
  harvest.spwn(stock)[,,,birthseas] <- 0
  m.spwn(stock)[,,,birthseas] <- 0

  # HARVEST
  harvest(stock) <- harvest(stock.n(stock), catch=catch.n(stock), m=m(stock))

  return(stock)

} # }}}

# readFLIBss3 {{{

#' A function to read the CPUE series from an SS3 run into an `FLIndex` object
#'
#' @references
#' Methot RD Jr, Wetzel CR (2013) Stock Synthesis: A biological and statistical
#' framework for fish stock assessment and fishery management.
#' Fisheries Research 142: 86-99.
#'
#' @param dir Directory containing the SS3 output files
#' @param birthseas The birthseasons for this stock as a numeric vector.
#' @param ... Any other argument to be passed to `r4ss::SS_output`
#'
#' @return An object of class [FLStock][FLCore::FLStock]
#'
#' @name readFLIBss3
#' @rdname readFLIBss3
#' @aliases readFLIBss3
#'
#' @author Iago Mosqueira, EC JRC
#' @seealso \link{FLComp}
#' @keywords classes

readFLIBss3 <- function(dir, fleets, birthseas=out$birthseas, ...) {

  # LOAD SS_output list
  out <- r4ss::SS_output(dir, verbose=FALSE, hidewarn=TRUE, warn=FALSE,
    printstats=FALSE, covar=FALSE, forecast=FALSE, ...)

  # TODO LOAD ctl$sizeselex, to match fleets if not given

  fleets <- unlist(fleets)
  
  # SUBSET from out
  out <- out[c("cpue", "ageselex", "endgrowth", "catage",
    "nsexes", "nseasons", "nareas", "birthseas")]
  cpue <- data.table(out[["cpue"]])
  selex <- data.table(out[["ageselex"]])
  endgrowth <- data.table(out[["endgrowth"]])
  wtatage <- endgrowth[BirthSeas %in% birthseas,
    c("Seas", "Sex", "BirthSeas", "Age", paste0("RetWt:_", fleets)), with=FALSE]
  catage <- data.table(out[["catage"]])
  setkey(catage, "Area", "Fleet", "Gender", "Morph", "Yr", "Seas", "Era")

  # --- index
  index <- ss3index(cpue, fleets)

  # --- index.var
  # index.var <- ss3index.var(cpue, fleets)

  # --- index.q
  index.q <- ss3index.q(cpue, fleets)

  # --- sel.pattern
  sel.pattern <- ss3sel.pattern(selex, unique(cpue$Yr), fleets,
    morphs=unique(selex$Morph))

  # --- index.var (var)
  index.var <- ss3index.var(cpue, fleets)

  # --- catch.n
  catch<- ss3catch(catage, wtatage, dmns=getDimnames(out, birthseas=birthseas),
    birthseas=birthseas, idx=fleets)
  catch.n <- lapply(catch, "[[", "landings.n")
  
  # --- FLIndices
  cpues <- lapply(names(fleets), function(x) FLIndexBiomass(name=x,
    index=index[[x]],
    index.q=index.q[[x]],
    index.var=index.var[[x]],
    catch.n=unitSums(window(catch.n[[x]], start=dims(index[[x]])$minyear,
      end=dims(index[[x]])$maxyear)),
    sel.pattern=window(sel.pattern[[x]], start=dims(index[[x]])$minyear,
      end=dims(index[[x]])$maxyear)))

  names(cpues) <- names(fleets)
 
  if(length(fleets) > 1)
    return(FLIndices(cpues))
  else
    return(cpues[[1]])

} # }}}

# readRPss3 {{{
readRPss3 <- function(file, vars=list(TotBio_Unfished=3, SPB_Virgin=3, SSB_MSY=3,
  SPB_endyr=3, F_endyr=3, Fstd_MSY=3, TotYield_MSY=3, `SR_LN(R0)`=3, LIKELIHOOD=2,
  Convergence_Level=2, Survey=2, Length_comp=2, Catch_like=2, Recruitment=2),
  endyr=missing) {

	dat <- readLines(file, n=2000)

  # GET endyr name
  if(missing(endyr)) {
    idx <- grep("SPB_", dat)
    elin <- unlist(strsplit(dat[idx[length(idx)]], " "))
    endyr <- sub("SPB_", "", elin[nchar(elin) > 1][1])
  }

  names(vars) <- sub("endyr", as.character(endyr), names(vars))

	for(i in names(vars)) {
		# vector with string
		str <- unlist(strsplit(dat[grep(paste0(gsub("\\(", "\\\\\\(", i), "[ ,:]"),
      dat, fixed=FALSE)], " "))
		vars[[i]] <- suppressWarnings(as.numeric(str[vars[[i]]]))
	}
	return(as.data.frame(t(unlist(vars))))
} # }}}

# readFLQsss3 {{{
readFLQsss3 <- function(dir, ...) {

  # LOAD SS_output list
  out <- r4ss::SS_output(dir, verbose=FALSE, hidewarn=TRUE, warn=FALSE,
    printstats=FALSE, covar=TRUE, forecast=FALSE, ...)

  # SUBSET out
  out <- out[c("derived_quants", "recruit", "startyr", "endyr", "Kobe")]

  yrs <- ac(seq(out$startyr, out$endyr))

  # REC
  recruit <- data.table(out$recruit)
  rec <- FLQuant(recruit[, pred_recr], dimnames=list(age='0', year=recruit[, Yr]),
    units="1000")[, yrs]

  # SPB
  ssb <- FLQuant(recruit[, SpawnBio], dimnames=list(age='all', year=recruit[, Yr]),
    units="t")[, yrs]

  # RESID
  resid <- FLQuant(recruit[, dev], dimnames=list(age='all', year=recruit[, Yr]),
    units="t")[, yrs]

  # BBMSY
  kobe <- data.table(out$Kobe)
  bbmsy <- FLQuant(kobe[, B.Bmsy], dimnames=list(age='all', year=kobe[, Year]),
    units="NA")[, yrs]

  ffmsy <- FLQuant(kobe[, F.Fmsy], dimnames=list(age='all', year=kobe[, Year]),
    units="NA")[, yrs]

  # $Dynamic_Bzero

  # $derived_quants
  # F_1950

  return(FLQuants(rec=rec, ssb=ssb, resid=resid, bbmsy=bbmsy, ffmsy=ffmsy))
} # }}}