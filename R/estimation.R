#' Run a grid search of the particle filter over R0 and start date.
#' This is parallelised, first run \code{plan(multiprocess)} to set
#' this up.
#'
#' @title Grid search of R0 and start date
#'
#' @param R0_min Minimum value of R0 in the search
#'
#' @param R0_max Maximum value of R0 in the search
#'
#' @param R0_step Step to increment R0 between min and max
#'
#' @param R0_prior Prior for R0. Default = NULL, which is a flat prior. Should be
#'  provided as a list with first argument the distribution function and the second
#'  the function arguments (excluding quantiles which are worked out based on
#'  R0_min and R0_max), e.g. `list("func" = dnorm, args = list("mean"= 3.5, "sd"= 3))`.
#'
#' @param Rt_func Function for converting R0, Meff and R0_change. Function must
#'   have names arguments of R0, Meff and R0_change. Default is linear relationship
#'   on the log scale given by \code{exp(log(R0) - Meff*(1-R0_change))}.
#'
#' @param first_start_date Earliest start date as 'yyyy-mm-dd'
#'
#' @param last_start_date Latest start date as 'yyyy-mm-dd'
#'
#' @param day_step Step to increment date in days
#'
#' @param data Deaths data to fit to. See \code{example_deaths.csv}
#'   and \code{particle_filter_data()}
#'
#' @param model_params Squire model parameters. Created from a call to one of
#'   the \code{parameters_<type>_model} functions.
#'
#' @param R0_change Numeric vector for relative changes in R0. Default = NULL,
#'   i.e. no change in R0
#'
#' @param date_R0_change Calendar dates at which R0_change occurs.
#'   Defaut = NULL, i.e. no change in R0
#'
#' @param date_contact_matrix_set_change Calendar dates at which the contact matrices
#'   set in \code{model_params} change. Defaut = NULL, i.e. no change
#'
#' @param date_ICU_bed_capacity_change Calendar dates at which ICU bed
#'   capacity changes set in \code{model_params} change.
#'   Defaut = NULL, i.e. no change
#'
#' @param date_hosp_bed_capacity_change Calendar dates at which hospital bed
#'   capacity changes set in \code{model_params} change.
#'   Defaut = NULL, i.e. no change
#'
#' @param squire_model A squire model. Default = \code{explicit_SEIR()}
#'
#' @param pars_obs list of parameters to use for the comparison function.
#'
#' @param n_particles Number of particles. Positive Integer. Default = 100
#'
#' @return List of R0 and start date grid values, and
#'   normalised probabilities at each point
#'
#' @import furrr
scan_R0_date <- function(
  R0_min,
  R0_max,
  R0_step,
  first_start_date,
  last_start_date,
  day_step,
  data,
  model_params,
  Rt_func = function(R0_change, R0, Meff){ exp(log(R0) - Meff*(1-R0_change)) },
  R0_prior = NULL,
  R0_change = NULL,
  date_R0_change = NULL,
  date_contact_matrix_set_change = NULL,
  date_ICU_bed_capacity_change = NULL,
  date_hosp_bed_capacity_change = NULL,
  squire_model = explicit_SEIR(),
  pars_obs = NULL,
  n_particles = 100) {

  ## Assertions

  assert_custom_class(squire_model, "squire_model")
  assert_custom_class(model_params, "squire_parameters")
  assert_pos(R0_min)
  assert_pos(R0_max)
  assert_date(first_start_date)
  assert_date(last_start_date)
  assert_pos_int(day_step)

  ## Set up parameter space to scan

  R0_1D <- seq(R0_min, R0_max, R0_step)
  date_list <- seq(as.Date(first_start_date), as.Date(last_start_date), day_step)
  param_grid <- expand.grid(R0 = R0_1D, start_date = date_list)

  # Set up observation parameters that translate our model outputs to observations
  if (is.null(pars_obs)) {
    pars_obs <-  list(phi_cases = 1,
                      k_cases = 2,
                      phi_death = 1,
                      k_death = 2,
                      exp_noise = 1e6)
  }

  #
  # Multi-core futures with furrr (parallel purrr)
  #
  ## Particle filter outputs, extracting log-likelihoods
  message("Running Grid Search...")

  if (Sys.getenv("SQUIRE_PARALLEL_DEBUG") == "TRUE") {

    pf_run_ll <- purrr::pmap_dbl(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = R0_change,
      date_R0_change = date_R0_change,
      date_contact_matrix_set_change = date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = date_hosp_bed_capacity_change,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = 0,
      save_particles = FALSE,
      Meff_include = FALSE,
      Rt_func = Rt_func,
      return = "ll")

  } else {

    pf_run_ll <- furrr::future_pmap_dbl(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = R0_change,
      date_R0_change = date_R0_change,
      date_contact_matrix_set_change = date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = date_hosp_bed_capacity_change,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = 0,
      save_particles = FALSE,
      Meff_include = FALSE,
      Rt_func = Rt_func,
      .progress = TRUE,
      return = "ll")

  }

  ## Construct a matrix with start_date as columns, and beta as rows
  ## order of return is set by order passed to expand.grid, above
  ## Returned column-major (down columns of varying beta) - set byrow = FALSE
  mat_log_ll <- matrix(
    pf_run_ll,
    nrow = length(R0_1D),
    ncol = length(date_list),
    byrow = FALSE)


  # apply prior post hoc
  if(!is.null(R0_prior)) {
    R0_prior$args$x <- R0_1D
    R0_prior$args$log <- TRUE
    mat_log_ll <- mat_log_ll + do.call(R0_prior[[1]], R0_prior[[2]])
  }

  # Exponentiate elements and normalise to 1 to get probabilities
  prob_matrix <- exp(mat_log_ll)
  renorm_mat_LL <- prob_matrix/sum(prob_matrix)

  # occasionally the likelihoods are so low that this creates NAs so just decrease
  drop <- 0.9
  while(any(is.na(renorm_mat_LL))) {
    prob_matrix <- exp(mat_log_ll*drop)
    renorm_mat_LL <- prob_matrix/sum(prob_matrix)
    drop <- drop^2
  }


  results <- list(x = R0_1D,
                  y = date_list,
                  mat_log_ll = mat_log_ll,
                  renorm_mat_LL = renorm_mat_LL,
                  inputs = list(
                    squire_model = squire_model,
                    model_params = model_params,
                    interventions = list(
                      R0_change = R0_change,
                      date_R0_change = date_R0_change,
                      date_contact_matrix_set_change = date_contact_matrix_set_change,
                      date_ICU_bed_capacity_change = date_ICU_bed_capacity_change,
                      date_hosp_bed_capacity_change = date_hosp_bed_capacity_change
                    ),
                    Rt_func = Rt_func,
                    pars_obs = pars_obs,
                    data = data))

  class(results) <- "squire_scan"
  results
}

#' Run a grid search of the particle filter over R0, start date and Meff.
#' This is parallelised, first run \code{plan(multiprocess)} to set
#' this up.
#'
#' @title Grid search of R0 and start date
#'
#' @param R0_min Minimum value of R0 in the search
#'
#' @param R0_max Maximum value of R0 in the search
#'
#' @param R0_step Step to increment R0 between min and max
#'
#' @param R0_prior Prior for R0. Default = NULL, which is a flat prior. Should be
#'  provided as a list with first argument the distribution function and the second
#'  the function arguments (excluding quantiles which are worked out based on
#'  R0_min and R0_max), e.g. \code{list("func" = dnorm, args = list("mean"= 3.5, "sd"= 3))}.
#'
#' @param Rt_func Function for converting R0, Meff and R0_change. Function must
#'   have names arguments of R0, Meff and R0_change. Default is linear relationship
#'   on the log scale given by \code{exp(log(R0) - Meff*(1-R0_change))}.
#'
#' @param first_start_date Earliest start date as 'yyyy-mm-dd'
#'
#' @param last_start_date Latest start date as 'yyyy-mm-dd'
#'
#' @param day_step Step to increment date in days
#'
#' @param Meff_min Minimum value of Meff (Movement effect size) in the search
#'
#' @param Meff_max Maximum value of Meff (Movement effect size) in the search
#'
#' @param Meff_step Step to increment Meff (Movement effect size) between min and max
#'
#' @param data Deaths data to fit to. See \code{example_deaths.csv}
#'   and \code{particle_filter_data()}
#'
#' @param model_params Squire model parameters. Created from a call to one of
#'   the \code{parameters_<type>_model} functions.
#'
#' @param R0_change Numeric vector for relative changes in R0. Default = NULL,
#'   i.e. no change in R0
#'
#' @param date_R0_change Calendar dates at which R0_change occurs.
#'   Defaut = NULL, i.e. no change in R0
#'
#' @param date_contact_matrix_set_change Calendar dates at which the contact matrices
#'   set in \code{model_params} change. Defaut = NULL, i.e. no change
#'
#' @param date_ICU_bed_capacity_change Calendar dates at which ICU bed
#'   capacity changes set in \code{model_params} change.
#'   Defaut = NULL, i.e. no change
#'
#' @param date_hosp_bed_capacity_change Calendar dates at which hospital bed
#'   capacity changes set in \code{model_params} change.
#'   Defaut = NULL, i.e. no change
#'
#' @param squire_model A squire model. Default = \code{explicit_SEIR()}
#'
#' @param pars_obs list of parameters to use for the comparison function.
#'
#' @param n_particles Number of particles. Positive Integer. Default = 100
#'
#' @return List of R0 and start date grid values, and
#'   normalised probabilities at each point
#'
#' @import furrr
scan_R0_date_Meff <- function(
  R0_min,
  R0_max,
  R0_step,
  first_start_date,
  last_start_date,
  day_step,
  Meff_min,
  Meff_max,
  Meff_step,
  data,
  model_params,
  Rt_func = function(R0_change, R0, Meff){ exp(log(R0) - Meff*(1-R0_change)) },
  R0_prior = NULL,
  R0_change = NULL,
  date_R0_change = NULL,
  date_contact_matrix_set_change = NULL,
  date_ICU_bed_capacity_change = NULL,
  date_hosp_bed_capacity_change = NULL,
  squire_model = explicit_SEIR(),
  pars_obs = NULL,
  n_particles = 100) {

  ## Assertions

  assert_custom_class(squire_model, "squire_model")
  assert_custom_class(model_params, "squire_parameters")
  assert_in(names(formals(Rt_func)), c("R0_change", "R0", "Meff"))
  assert_pos(R0_min)
  assert_pos(R0_max)
  assert_numeric(Meff_max)
  assert_numeric(Meff_min)
  assert_pos(Meff_step)
  assert_date(first_start_date)
  assert_date(last_start_date)
  assert_pos_int(day_step)

  ## Set up parameter space to scan

  R0_1D <- seq(R0_min, R0_max, R0_step)
  date_list <- seq(as.Date(first_start_date), as.Date(last_start_date), day_step)
  Meff_1D <- seq(Meff_min, Meff_max, Meff_step)
  param_grid <- expand.grid(R0 = R0_1D, start_date = date_list, Meff = Meff_1D)

  # Set up observation parameters that translate our model outputs to observations
  if (is.null(pars_obs)) {
    pars_obs <-  list(phi_cases = 1,
                      k_cases = 2,
                      phi_death = 1,
                      k_death = 2,
                      exp_noise = 1e6)
  }

  #
  # Multi-core futures with furrr (parallel purrr)
  #
  ## Particle filter outputs, extracting log-likelihoods
  message("Running Grid Search...")

  if (Sys.getenv("SQUIRE_PARALLEL_DEBUG") == "TRUE") {

    pf_run_ll <- purrr::pmap_dbl(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = R0_change,
      date_R0_change = date_R0_change,
      date_contact_matrix_set_change = date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = date_hosp_bed_capacity_change,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = 0,
      save_particles = FALSE,
      Meff_include = TRUE,
      Rt_func = Rt_func,
      return = "ll")

  } else {

    pf_run_ll <- furrr::future_pmap_dbl(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = R0_change,
      date_R0_change = date_R0_change,
      date_contact_matrix_set_change = date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = date_hosp_bed_capacity_change,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = 0,
      save_particles = FALSE,
      .progress = TRUE,
      Meff_include = TRUE,
      Rt_func = Rt_func,
      return = "ll")

  }

  ## Construct a matrix with start_date as columns, and beta as rows
  ## order of return is set by order passed to expand.grid, above
  ## Returned column-major (down columns of varying beta) - set byrow = FALSE
  mat_log_ll <- array(
    pf_run_ll,
    dim = c(length(R0_1D), length(date_list), length(Meff_1D))
  )

  # apply prior post hoc
  if(!is.null(R0_prior)) {
    R0_prior$args$x <- R0_1D
    R0_prior$args$log <- TRUE
    mat_log_ll <- mat_log_ll + do.call(R0_prior[[1]], R0_prior[[2]])
  }

  # Exponentiate elements and normalise to 1 to get probabilities
  prob_matrix <- exp(mat_log_ll)
  renorm_mat_LL <- prob_matrix/sum(prob_matrix)

  # occasionally the likelihoods are so low that this creates NAs so just decrease
  drop <- 0.9
  while(any(is.na(renorm_mat_LL))) {
    prob_matrix <- exp(mat_log_ll*drop)
    renorm_mat_LL <- prob_matrix/sum(prob_matrix)
    drop <- drop^2
  }


  results <- list(x = R0_1D,
                  y = date_list,
                  z = Meff_1D,
                  labs = c("R0", "Start Date", "Mobility Effect Size"),
                  mat_log_ll = mat_log_ll,
                  renorm_mat_LL = renorm_mat_LL,
                  inputs = list(
                    squire_model = squire_model,
                    model_params = model_params,
                    interventions = list(
                      R0_change = R0_change,
                      date_R0_change = date_R0_change,
                      date_contact_matrix_set_change = date_contact_matrix_set_change,
                      date_ICU_bed_capacity_change = date_ICU_bed_capacity_change,
                      date_hosp_bed_capacity_change = date_hosp_bed_capacity_change
                    ),
                    Rt_func = Rt_func,
                    pars_obs = pars_obs,
                    data = data))

  class(results) <- "squire_scan"
  results
}

#' Particle filter outputs
#'
#' Helper function to run the particle filter with a
#' new R0 and start date for given interventions.
#'
#' @noRd
R0_date_particle_filter <- function(R0,
                                    start_date,
                                    squire_model,
                                    model_params,
                                    data,
                                    R0_change,
                                    date_R0_change,
                                    date_contact_matrix_set_change,
                                    date_ICU_bed_capacity_change,
                                    date_hosp_bed_capacity_change,
                                    pars_obs,
                                    n_particles,
                                    Meff = 1,
                                    Meff_include = FALSE,
                                    Rt_func = function(R0_change, R0, Meff){ exp(log(R0) - Meff*(1-R0_change)) },
                                    forecast_days = 0,
                                    save_particles = FALSE,
                                    full_output = FALSE,
                                    return = "full") {

  # first set up our new timings for the new start date
  if (is.null(date_R0_change)) {
    tt_beta <- 0
  } else {
    tt_list <- intervention_dates_for_odin(dates = date_R0_change,
                                           change = R0_change,
                                           start_date = start_date,
                                           steps_per_day = round(1/model_params$dt))
    model_params$tt_beta <- unique(c(0, tt_list$tt))
    R0_change <- tt_list$change

  }

  if (is.null(date_contact_matrix_set_change)) {
    tt_contact_matrix <- 0
  } else {
    tt_list <- intervention_dates_for_odin(dates = date_contact_matrix_set_change,
                                           change = model_params$contact_matrix_set[-1],
                                           start_date = start_date,
                                           steps_per_day = round(1/model_params$dt))

    model_params$tt_contact_matrix <- unique(c(0, tt_list$tt))
    model_params$contact_matrix_set <- append(model_params$contact_matrix_set[1], tt_list$change)

  }

  if (is.null(date_ICU_bed_capacity_change)) {
    tt_ICU_beds <- 0
  } else {
    tt_list <- intervention_dates_for_odin(dates = date_ICU_bed_capacity_change,
                                           change = model_params$ICU_beds[-1],
                                           start_date = start_date,
                                           steps_per_day = round(1/model_params$dt))

    model_params$tt_ICU_beds <- unique(c(0, tt_list$tt))
    model_params$ICU_beds <- c(model_params$ICU_beds[1], tt_list$change)

  }

  if (is.null(date_hosp_bed_capacity_change)) {
    tt_hosp_beds <- 0
  } else {
    tt_list <- intervention_dates_for_odin(dates = date_hosp_bed_capacity_change,
                                           change = model_params$hosp_beds[-1],
                                           start_date = start_date,
                                           steps_per_day = round(1/model_params$dt))

    model_params$tt_hosp_beds <- unique(c(0, tt_list$tt))
    model_params$hosp_beds <- c(model_params$hosp_beds[1], tt_list$change)

  }

  # Second create the new R0s for the R0 and any changes to Meff
  if (!is.null(R0_change)) {
    if (Meff_include) {
      #R0 <- c(R0, exp(log(R0) - Meff*(1-R0_change)))
      R0 <- c(R0, vapply(R0_change, function(x){
        Rt_func(R0_change = x, R0 = R0, Meff = Meff)
      }, FUN.VALUE = numeric(1)))
    } else {
      R0 <- c(R0, R0 * R0_change)
    }
  }

  # and work out our beta
  beta_set <- beta_est(squire_model = squire_model,
                       model_params = model_params,
                       R0 = R0)

  # update the model params accordingly
  model_params$beta_set <- beta_set

  # run the particle filter
  if (inherits(squire_model, "stochastic")) {

    X <- run_particle_filter(data = data,
                             squire_model = squire_model,
                             model_params = model_params,
                             model_start_date = start_date,
                             obs_params = pars_obs,
                             n_particles = n_particles,
                             forecast_days = forecast_days,
                             full_output = full_output,
                             save_particles = save_particles,
                             return = return)

  } else {

    X <- run_deterministic_comparison(data = data,
                                      squire_model = squire_model,
                                      model_params = model_params,
                                      model_start_date = start_date,
                                      obs_params = pars_obs,
                                      forecast_days = forecast_days,
                                      save_history = save_particles,
                                      return = return)

  }

  X
}

#' Take a grid search produced by \code{\link{scan_R0_date}} and
#' sample \code{n_sample_pairs} from the parameter grid uses based
#' on their probability. For each parameter pair chosen, run particle
#' filter with \code{num_particles} and sample 1 trajectory
#'
#' @title Sample Grid Scan
#'
#' @param scan_results Output of \code{\link{scan_R0_date}}.
#'
#' @param n_sample_pairs Number of parameter pairs to be sampled. This will
#'   determine how many trajectories are returned. Integer. Default = 10. This
#'   will determine how many trajectories are returned.
#'
#' @param n_particles Number of particles. Positive Integer. Default = 100
#'
#' @param forecast_days Number of days being forecast. Default = 0
#'
#' @param full_output Logical, indicating whether the full model output,
#'   including the state and the declared outputs are returned. Deafult = FALSE
#'
#' @return \code{\link{list}}. First element (trajectories) is a 3
#'   dimensional array of trajectories (time, state, tranjectories). Second
#'   element (param_grid) is the parameters chosen when  sampling from the
#'   \code{scan_results} grid and the third dimension (inputs) is a list of
#'   model inputs.
#'
#' @import furrr
#' @importFrom utils tail
sample_grid_scan <- function(scan_results,
                             n_sample_pairs = 10,
                             n_particles = 100,
                             forecast_days = 0,
                             full_output = FALSE) {

  # checks on args
  assert_custom_class(scan_results, "squire_scan")
  assert_pos_int(n_sample_pairs)
  assert_pos_int(n_particles)
  assert_pos_int(forecast_days)

  # grab the pobability matrix
  prob <- scan_results$renorm_mat_LL
  nr <- nrow(prob)
  nc <- ncol(prob)

  # construct what the grid of beta and start values that
  # correspond to the z axis matrix
  x_grid <- matrix(scan_results$x, nrow = nr, ncol = nc)
  y_grid <- matrix(as.character(scan_results$y), nrow = nr,
                   ncol = nc, byrow = TRUE)

  # draw which grid pairs are chosen
  pairs <- sample(x =  length(prob), size = n_sample_pairs,
                  replace = TRUE, prob = prob)

  # what are related beta and dates
  R0 <- x_grid[pairs]
  dates <- y_grid[pairs]

  # recreate parameters for re running
  param_grid <- data.frame("R0" = R0, "start_date" = dates, stringsAsFactors = FALSE)
  squire_model <- scan_results$inputs$squire_model
  model_params <- scan_results$inputs$model_params
  pars_obs <- scan_results$inputs$pars_obs
  data <- scan_results$inputs$data


  # Multi-core futures with furrr (parallel purrr)

  ## Particle filter outputs

  # traces <- purrr::pmap(
  message("Sampling from grid...")

  if (Sys.getenv("SQUIRE_PARALLEL_DEBUG") == "TRUE") {
    traces <- purrr::pmap(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = scan_results$inputs$interventions$R0_change,
      date_R0_change = scan_results$inputs$interventions$date_R0_change,
      date_contact_matrix_set_change = scan_results$inputs$interventions$date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = scan_results$inputs$interventions$date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = scan_results$inputs$interventions$date_hosp_bed_capacity_change,
      Rt_func = scan_results$inputs$Rt_func,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = forecast_days,
      full_output = full_output,
      Meff_include = FALSE,
      save_particles = TRUE,
      return = "sample"
    )
  } else {
    traces <- furrr::future_pmap(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = scan_results$inputs$interventions$R0_change,
      date_R0_change = scan_results$inputs$interventions$date_R0_change,
      date_contact_matrix_set_change = scan_results$inputs$interventions$date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = scan_results$inputs$interventions$date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = scan_results$inputs$interventions$date_hosp_bed_capacity_change,
      Rt_func = scan_results$inputs$Rt_func,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = forecast_days,
      full_output = full_output,
      save_particles = TRUE,
      Meff_include = FALSE,
      return = "sample",
      .progress = TRUE
    )
  }
  # collapse into an array of trajectories
  # the trajectories are different lengths in terms of dates
  # so we will fill the arrays with NAs where needed
  num_rows <- unlist(lapply(traces, nrow))
  max_rows <- max(num_rows)
  seq_max <- seq_len(max_rows)
  max_date_names <- rownames(traces[[which.max(unlist(lapply(traces, nrow)))]])

  trajectories <- array(NA,
                        dim = c(max_rows, ncol(traces[[1]]), length(traces)),
                        dimnames = list(max_date_names, colnames(traces[[1]]), NULL))

  # fill the tail of the array slice
  # This is so that the end of the trajectories array is populated,
  # and the start is padded with NA if it's shorter than the max.
  for (i in seq_len(length(traces))){
    trajectories[tail(seq_max, nrow(traces[[i]])), , i] <- traces[[i]]
  }

  # combine and return
  res <- list("trajectories" = trajectories,
              "param_grid" = param_grid,
              inputs = list(
                model_params = model_params,
                pars_obs = pars_obs,
                data = data,
                squire_model = squire_model))

  class(res) <- "sample_grid_search"

  return(res)

}


#' Take a grid search produced by \code{\link{scan_R0_date_Meff}} and
#' sample \code{n_sample_pairs} from the parameter grid uses based
#' on their probability. For each parameter pair chosen, run particle
#' filter with \code{num_particles} and sample 1 trajectory
#'
#' @title Sample Grid Scan
#'
#' @param scan_results Output of \code{\link{scan_R0_date_Meff}}.
#'
#' @param n_sample_pairs Number of parameter pairs to be sampled. This will
#'   determine how many trajectories are returned. Integer. Default = 10. This
#'   will determine how many trajectories are returned.
#'
#' @param n_particles Number of particles. Positive Integer. Default = 100
#'
#' @param forecast_days Number of days being forecast. Default = 0
#'
#' @param full_output Logical, indicating whether the full model output,
#'   including the state and the declared outputs are returned. Deafult = FALSE
#'
#' @return \code{\link{list}}. First element (trajectories) is a 3
#'   dimensional array of trajectories (time, state, tranjectories). Second
#'   element (param_grid) is the parameters chosen when  sampling from the
#'   \code{scan_results} grid and the third dimension (inputs) is a list of
#'   model inputs.
#'
#' @import furrr
#' @importFrom utils tail
sample_3d_grid_scan <- function(scan_results,
                                n_sample_pairs = 10,
                                n_particles = 100,
                                forecast_days = 0,
                                full_output = FALSE) {

  # checks on args
  assert_custom_class(scan_results, "squire_scan")
  assert_pos_int(n_sample_pairs)
  assert_pos_int(n_particles)
  assert_pos_int(forecast_days)

  # grab the pobability matrix
  prob <- scan_results$renorm_mat_LL
  dm <- dim(prob)

  # construct what the grid of beta and start values that
  # correspond to the z axis matrix
  x_grid <- array(scan_results$x, dm)
  y_grid <- array(mapply(rep, scan_results$y, length(scan_results$x)), dm)
  z_grid <- array(mapply(rep, scan_results$z, length(scan_results$x)*length(scan_results$y)), dm)

  # draw which grid pairs are chosen
  pairs <- sample(x =  length(prob), size = n_sample_pairs,
                  replace = TRUE, prob = prob)

  # what are related beta and dates
  R0 <- x_grid[pairs]
  dates <- y_grid[pairs]
  Meff <- z_grid[pairs]

  # recreate parameters for re running
  param_grid <- data.frame("R0" = R0, "start_date" = dates, "Meff" = Meff, stringsAsFactors = FALSE)
  param_grid$start_date <- scan_results$y[match(param_grid$start_date, as.numeric(scan_results$y))]
  squire_model <- scan_results$inputs$squire_model
  model_params <- scan_results$inputs$model_params
  pars_obs <- scan_results$inputs$pars_obs
  data <- scan_results$inputs$data


  # Multi-core futures with furrr (parallel purrr)

  ## Particle filter outputs

  # traces <- purrr::pmap(
  message("Sampling from grid...")

  if (Sys.getenv("SQUIRE_PARALLEL_DEBUG") == "TRUE") {
    traces <- purrr::pmap(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = scan_results$inputs$interventions$R0_change,
      date_R0_change = scan_results$inputs$interventions$date_R0_change,
      date_contact_matrix_set_change = scan_results$inputs$interventions$date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = scan_results$inputs$interventions$date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = scan_results$inputs$interventions$date_hosp_bed_capacity_change,
      Rt_func = scan_results$inputs$Rt_func,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = forecast_days,
      full_output = full_output,
      save_particles = TRUE,
      Meff_include = TRUE,
      return = "sample"
    )
  } else {
    traces <- furrr::future_pmap(
      .l = param_grid,
      .f = R0_date_particle_filter,
      squire_model = squire_model,
      model_params = model_params,
      data = data,
      R0_change = scan_results$inputs$interventions$R0_change,
      date_R0_change = scan_results$inputs$interventions$date_R0_change,
      date_contact_matrix_set_change = scan_results$inputs$interventions$date_contact_matrix_set_change,
      date_ICU_bed_capacity_change = scan_results$inputs$interventions$date_ICU_bed_capacity_change,
      date_hosp_bed_capacity_change = scan_results$inputs$interventions$date_hosp_bed_capacity_change,
      Rt_func = scan_results$inputs$Rt_func,
      pars_obs = pars_obs,
      n_particles = n_particles,
      forecast_days = forecast_days,
      full_output = full_output,
      save_particles = TRUE,
      Meff_include = TRUE,
      return = "sample",
      .progress = TRUE
    )
  }
  # collapse into an array of trajectories
  # the trajectories are different lengths in terms of dates
  # so we will fill the arrays with NAs where needed
  num_rows <- unlist(lapply(traces, nrow))
  max_rows <- max(num_rows)
  seq_max <- seq_len(max_rows)
  max_date_names <- rownames(traces[[which.max(unlist(lapply(traces, nrow)))]])

  trajectories <- array(NA,
                        dim = c(max_rows, ncol(traces[[1]]), length(traces)),
                        dimnames = list(max_date_names, colnames(traces[[1]]), NULL))

  # fill the tail of the array slice
  # This is so that the end of the trajectories array is populated,
  # and the start is padded with NA if it's shorter than the max.
  for (i in seq_len(length(traces))){
    trajectories[tail(seq_max, nrow(traces[[i]])), , i] <- traces[[i]]
  }

  # combine and return
  res <- list("trajectories" = trajectories,
              "param_grid" = param_grid,
              inputs = list(
                model_params = model_params,
                pars_obs = pars_obs,
                data = data,
                squire_model = squire_model))

  class(res) <- "sample_grid_search"

  return(res)

}

#' squire scan plot
#'
#' @param x An squire_scan object
#' @param what What scan outputs are we plotting of "likelihood" vs "probability"
#' @param log Should the axes by plotted on log scale
#' @param show Which dimensions of the scan to show. Default = c(1, 2)
#' @param ... additional arguments affecting the plot produced.
#'
#' @export
plot.squire_scan <- function(x, ..., what = "likelihood", log = FALSE, show = c(1,2)) {

  # is it greater than 2d
  if (length(dim(x$mat_log_ll)) > 2) {
    x$renorm_mat_LL <- apply(x$renorm_mat_LL, show, sum)
    x$mat_log_ll <- apply(x$mat_log_ll, show, mean)
    x$x <- x[[show[1]]]
    x$y <- x[[show[2]]]
    xlab <- x$labs[show[1]]
    ylab <- x$labs[show[2]]
  } else {
    xlab <- "R0"
    ylab <- "Start Date"
  }

  if (what == "likelihood") {

    # create df
    df <- data.frame("z" = as.numeric(x$mat_log_ll))
    df$x <- x$x
    df$y <- sort(rep(x$y, length(x$x)))

    # make plot
    gg <- ggplot2::ggplot(data=df, ggplot2::aes(x=.data$x,y=.data$y,fill=-.data$z)) +
      ggplot2::geom_tile(color = "white") +
      ggplot2::xlab(xlab) +
      ggplot2::ylab(ylab) +
      ggplot2::scale_fill_gradient(name = "-Log L.") +
      ggplot2::theme_bw() +
      ggplot2::theme(
        panel.grid = ggplot2::element_blank(),
        panel.border = ggplot2::element_blank(),
        plot.title = ggplot2::element_text(hjust = 0.5)) +
      ggplot2::ggtitle("Likelihood")

    if(log) {
      gg <- gg + ggplot2::scale_fill_gradient( name = "-Log L.", trans = 'log' )
    }


  } else if (what == "probability") {

    # create df
    df <- data.frame("z" = as.numeric(x$renorm_mat_LL))
    df$x <- x$x
    df$y <- sort(rep(x$y, length(x$x)))

    # make plot
    gg <- ggplot2::ggplot(data=df, ggplot2::aes(x=.data$x,y=.data$y,fill=.data$z)) +
      ggplot2::geom_tile(color = "white") +
      ggplot2::xlab(xlab) +
      ggplot2::ylab(ylab) +
      ggplot2::scale_fill_gradient(name = "Probability", low = "#56B1F7", high = "#132B43") +
      ggplot2::theme_bw() +
      ggplot2::theme(
        panel.grid = ggplot2::element_blank(),
        panel.border = ggplot2::element_blank(),
        plot.title = ggplot2::element_text(hjust = 0.5)) +
      ggplot2::ggtitle("Probability")

    if(log) {
      gg <- gg + ggplot2::scale_fill_gradient(name = "Probability", trans = 'log',
                                              low = "#56B1F7", high = "#132B43")
    }
  }

  # adjust axes
  if(class(x$x) == "numeric") {
    gg <- gg + ggplot2::scale_x_continuous(expand = c(0, 0))
  } else if (inherits(x$x, "Date")) {
    gg <- gg + ggplot2::scale_x_date(expand = c(0, 0))
  }


  if(class(x$y) == "numeric") {
    gg <- gg + ggplot2::scale_y_continuous(expand = c(0, 0))
  } else if (inherits(x$y, "Date")) {
    gg <- gg + ggplot2::scale_y_date(expand = c(0, 0))
  }


  return(gg)
}


#' @noRd
plot_sample_grid_search <- function(x, what = "deaths") {

  idx <- odin_index(x$model)

  # what are we plotting
  if (what == "cases") {

    index <- unlist(
      idx[c("IMild", "ICase1", "ICase2", "IOxGetLive1", "IOxGetLive2",
            "IOxGetDie1", "IOxGetDie2", "IOxNotGetLive1", "IOxNotGetLive2",
            "IOxNotGetDie1", "IOxNotGetDie2", "IMVGetLive1", "IMVGetLive2",
            "IMVGetDie1", "IMVGetDie2", "IMVNotGetLive1", "IMVNotGetLive2",
            "IMVNotGetDie1", "IMVNotGetDie2", "IRec1", "IRec2", "R", "D")])
    ylab <- "Cumulative Cases"
    xlab <- "Date"
    particles <- vapply(seq_len(dim(x$output)[3]), function(y) {
      rowSums(x$output[,index,y], na.rm = TRUE)},
      FUN.VALUE = numeric(dim(x$output)[1]))
    quants <- as.data.frame(t(apply(particles, 1, quantile, c(0.025, 0.975))))
    quants$date <- rownames(quants)
    names(quants)[1:2] <- c("ymin","ymax")

    base_plot <- plot(x, "infections", ci = FALSE, replicates = TRUE, x_var = "date",
                      date_0 = max(x$scan_results$inputs$data$date))
    base_plot <- base_plot +
      ggplot2::geom_line(ggplot2::aes(y=.data$ymin, x=as.Date(.data$date)), quants, linetype="dashed") +
      ggplot2::geom_line(ggplot2::aes(y=.data$ymax, x=as.Date(.data$date)), quants, linetype="dashed") +
      ggplot2::geom_point(ggplot2::aes(y=.data$cases, x=as.Date(.data$date)), x$scan_results$inputs$data)

  }

  else if(what == "deaths") {

    index <- c(idx$D)
    ylab <- "Deaths"
    xlab <- "Date"
    particles <- vapply(seq_len(dim(x$output)[3]), function(y) {
      out <- c(0,diff(rowSums(x$output[,index,y], na.rm = TRUE)))
      names(out)[1] <- rownames(x$output)[1]
      out},
      FUN.VALUE = numeric(dim(x$output)[1]))
    quants <- as.data.frame(t(apply(particles, 1, quantile, c(0.025, 0.975))))
    quants$date <- rownames(quants)
    names(quants)[1:2] <- c("ymin","ymax")

    base_plot <- plot(x, "deaths", ci = FALSE, replicates = TRUE, x_var = "date",
                      date_0 = max(x$scan_results$inputs$data$date))
    base_plot <- base_plot +
      ggplot2::geom_line(ggplot2::aes(y=.data$ymin, x=as.Date(.data$date)), quants, linetype="dashed") +
      ggplot2::geom_line(ggplot2::aes(y=.data$ymax, x=as.Date(.data$date)), quants, linetype="dashed") +
      ggplot2::geom_point(ggplot2::aes(y=.data$deaths,x=as.Date(.data$date)), x$scan_results$inputs$data)

  } else {

    stop("Requested what must be one of 'cases', 'deaths'")

  }

  base_plot <-  base_plot +
    ggplot2::ylab(ylab) +
    ggplot2::xlab(xlab) +
    ggplot2::theme(legend.position = "none")
  return(base_plot)


}

