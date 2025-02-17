utils::globalVariables(c("n_tot", "prob", "probs", ".", "post_gen_liab", 
                         "post_gen_liab_se", "grp_est", "grp_se", "est_per_sib",
                         "cases", "child_gen"))

#' Estimate genetic liability similar to LT-FH
#'
#' @param h2 Liability scale heritability of the trait being analysed.
#' @param phen tibble or data.frame with status of the genotyped individual, parents and siblings.
#' @param child_threshold single numeric value that is used as threshold for the offspring and siblings.
#' @param parent_threshold single numeric value that is used as threshold for both parents
#' @param status_col_offspring Column name of status for the offspring
#' @param status_col_father Column name of status for the father
#' @param status_col_mother Column name of status for the mother
#' @param status_col_siblings Column name of status for the siblings
#' @param number_of_siblings_col Column name for the number of siblings for a given individual
#' @param tol Convergence criteria of the gibbs sampler. Default is 0.01, meaning a standard error of the mean below 0.01
#'
#' @return Returns the estimated genetic liabilities.
#'
#' @examples 
#' # See R/Example/example_nosib.R for an example of use and input.
#' @importFrom dplyr %>%
#' @export


estimate_gen_liability_ltfh = function(h2,
                                       phen, 
                                       child_threshold,
                                       parent_threshold,
                                       status_col_offspring   = "CHILD_STATUS",
                                       status_col_father      = "P1_STATUS", 
                                       status_col_mother      = "P2_STATUS",
                                       status_col_siblings    = "SIB_STATUS",
                                       number_of_siblings_col = "NUM_SIBS",
                                       tol = 0.01) {
  
  if (!requireNamespace("tmvtnorm", quietly = TRUE))
    stop("Please install package 'tmvtnorm'.")
  
  # Find all unique combinations of status ----------------------------------


  reduced = phen %>% 
    dplyr::select(!!as.symbol(status_col_offspring),
                  !!as.symbol(status_col_father),
                  !!as.symbol(status_col_mother), 
                  !!as.symbol(status_col_siblings), 
                  !!as.symbol(number_of_siblings_col)) %>% 
    dplyr::group_by(!!as.symbol(status_col_offspring),
                    !!as.symbol(status_col_father),
                    !!as.symbol(status_col_mother), 
                    !!as.symbol(status_col_siblings), 
                    !!as.symbol(number_of_siblings_col)) %>% 
    dplyr::slice_head() %>%
    dplyr::ungroup() #extract each unique configuration present in the data.
  
  progress_bar_n = 1:nrow(reduced)
  pbn = 1
  p <- progressr::progressor(along = progress_bar_n)
  
  
  reduced$post_gen_liab <- NA
  reduced$post_gen_liab_se <- NA
  

  # All cases with no sibling status ----------------------------------------
  reduced_max_1_sibling = reduced %>% dplyr::filter(!!as.symbol(status_col_siblings) == 0)
 
  if(nrow(reduced_max_1_sibling) > 0) { #only do this if we actually have configurations in the data.
    for (i in 1:nrow(reduced_max_1_sibling)) {
      #extract number of siblings and construct the thresholds and covariance matrix
      cur_nsib = unlist(reduced_max_1_sibling[i, 5])
      full_fam = c(unlist(reduced_max_1_sibling[i,1:3]), rep(0, cur_nsib))
      
      cov = get_cov(h2 = h2, n_sib = cur_nsib)
      
      cov_size = nrow(cov)
      
      lower = rep(-Inf, cov_size)
      upper = rep(Inf, cov_size) 
      
      #assigning thresholds for parents:
      upper[-1][2:3][full_fam[2:3] == 0] = parent_threshold
      lower[-1][2:3][full_fam[2:3] == 1] = parent_threshold
      #assigning thresholds for parents:
      upper[2][full_fam[1] == 0] = child_threshold
      lower[2][full_fam[1] == 1] = child_threshold
      
      if (cur_nsib > 0) {
        upper[4 + 1:cur_nsib] = child_threshold
      }
      
      fixed <- (upper - lower) < 1e-4
      
      # estimate genetic liability & covergence check
      se = NULL 
      vals = list() #store simulated values
      vals.ctr = 1
      while (is.null(se) || se > tol) {
        gen_liabs = rtmvnorm.gibbs(50e3, 
                                   burn_in = 1000,
                                   sigma = cov,
                                   lower = lower, 
                                   upper = upper,
                                   fixed = fixed)
        vals[[vals.ctr]] = gen_liabs
        se = batchmeans::bm(unlist(vals))$se
        vals.ctr =  vals.ctr + 1
      }
      #calculate the final values
      est = batchmeans::bm(unlist(vals))
      reduced_max_1_sibling$post_gen_liab[i]    = est$est
      reduced_max_1_sibling$post_gen_liab_se[i] = est$se
      
      p(sprintf("%g", pbn))
      pbn = pbn + 1
    }
  }


  # All configurations with sibling status ----------------------------------
  
  reduced_atleast_2_siblings = reduced %>% dplyr::filter(!!as.symbol(number_of_siblings_col) > 1, !!as.symbol(status_col_siblings) == 1)
  
  if(nrow(reduced_atleast_2_siblings) > 0) {
    
    # Estimate probabilities of having n siblings as case ---------------------
    reduced_atleast_2_siblings$probs = lapply(1:nrow(reduced_atleast_2_siblings), FUN = function(n) {
      cur_nsib = unlist(reduced_atleast_2_siblings[n, 5])
      lower = rep(-Inf, 4 + cur_nsib) 
      upper = rep( Inf, 4 + cur_nsib)
      cur_stat = unlist(reduced_atleast_2_siblings[n,1:3])
      
      
      #assigning thresholds for parents:
      lower[3:4][(cur_stat[-1] == 1)] = parent_threshold
      upper[3:4][(cur_stat[-1] != 1)] = parent_threshold
      #assigning thresholds for children:
      lower[2][(cur_stat[1] == 1)] = child_threshold
      upper[2][(cur_stat[1] != 1)] = child_threshold
      
      tmp <- tmvtnorm::rtmvnorm(n = 100e3, mean = rep(0, 4 + cur_nsib), sigma = get_cov(h2, n_sib = cur_nsib),
                                lower = lower,
                                upper = upper, 
                                algorithm = "gibbs") 
      colnames(tmp) = c("child_gen", paste0(c("child", "father", "mother", paste0("sib", 1:cur_nsib)), "_full"))
      tmp = dplyr::as_tibble(tmp)
      
      cur_string = paste(reduced_atleast_2_siblings[n,1:3], collapse = " ")
      tmp[,3:4] = (tmp[,3:4] > parent_threshold) + 0
      tmp[,-c(1,3:4)] = (tmp[,-c(1,3:4)] > child_threshold) + 0
      #dplyr::mutate_all(tmp, .funs =  trans2 ) %>%
      # dplyr::mutate_all(.funs = trans) %>% 
      tmp %>%
        dplyr::select(-child_gen) %>%
        dplyr::group_by_all() %>%
        dplyr::summarise(n = n(), .groups = 'drop') %>% 
        dplyr::mutate("cases" = (dplyr::select(., dplyr::contains("sib")) %>% rowSums)) %>% 
        dplyr::filter(cases != 0) %>%
        dplyr::select(-dplyr::contains("sib")) %>%
        dplyr::group_by(dplyr::select(., -n)) %>%
        dplyr::summarise(n = sum(n), .groups = 'drop') %>% 
        dplyr::mutate(string = do.call(paste, dplyr::select(.,1:3))) %>% 
        dplyr::select(-dplyr::contains("full")) %>% 
        dplyr::filter(string == cur_string) %>%
        dplyr::mutate(n_tot = sum(n)) %>%
        dplyr::mutate(prob = n / n_tot) %>% 
        dplyr::arrange(cases) %>% 
        dplyr::pull(prob) 
    })
    
    
    # Estimate genetic liability of having n siblings as case -----------------
    
    reduced_atleast_2_siblings[["est_per_sib"]] = list(c())
    for (i in 1:nrow(reduced_atleast_2_siblings)) {
      #extract number of siblings
      cur_nsib = unlist(reduced_atleast_2_siblings[i, 5])
      #construct all combinations of sibling cases
      combs = expand.grid(lapply(1:cur_nsib, FUN = function(x) c(0,1)))
      res = list("post_gen_liab"    = numeric(nrow(combs) - 1),
                 "post_gen_liab_se" = numeric(nrow(combs) - 1))
      for (j in 2:nrow(combs)) { #estimate genetic liability in each configuration
        cur_stat = c(unlist(reduced_atleast_2_siblings[i,1:3]),unlist(combs[j,]))
        lower = rep(-Inf, 4 + ncol(combs))
        upper = rep(Inf,  4 + ncol(combs))
        
        #assigning thresholds for parents:
        lower[3:4][(cur_stat[c(2:3)] == 1)] = parent_threshold
        upper[3:4][(cur_stat[c(2:3)] != 1)] = parent_threshold
        #assigning thresholds for children:
        lower[-c(1, 3:4)][(cur_stat[-c(2:3)] == 1)] = child_threshold
        upper[-c(1, 3:4)][(cur_stat[-c(2:3)] != 1)] = child_threshold
        
        fixed = upper - lower < 1e-3
        
        #covergence check
        se = NULL 
        vals = list() #store simulated values
        vals.ctr = 1
        while (is.null(se) || se > tol) {
          gen_liabs = LTFHPlus::rtmvnorm.gibbs(n_sim = 50e3,
                                               sigma = get_cov(h2, n_sib = cur_nsib),
                                               lower = lower,
                                               upper = upper,
                                               fixed = fixed,
                                               ind = 1,
                                               burn_in = 1000)
          vals[[vals.ctr]] = gen_liabs
          se = batchmeans::bm(unlist(vals))$se
          vals.ctr =  vals.ctr + 1
        }
        #calculate the final values
        est = batchmeans::bm(unlist(vals))
        res$post_gen_liab[j - 1]    = est$est
        res$post_gen_liab_se[j - 1] = est$se
        
      }
      #combine the estimates into 1 siblings being a case, and 2 being a case ... to n.
      reduced_atleast_2_siblings$est_per_sib[[i]] =  dplyr::as_tibble(cbind(combs[-1,], res)) %>%
        dplyr::mutate(string = rowSums(dplyr::select(., 1:ncol(combs)))) %>%
        dplyr::group_by(string) %>%
        dplyr::summarise(grp_est = mean(post_gen_liab), .groups = "drop") %>% dplyr::arrange(string) %>% dplyr::pull(grp_est)
      #naive sd estimate:
      reduced_atleast_2_siblings$post_gen_liab_se[[i]] =  dplyr::as_tibble(cbind(combs[-1,], res)) %>%
        dplyr::summarise(grp_se  = mean(post_gen_liab_se), .groups = "drop") %>%  dplyr::pull(grp_se)
      
      p(sprintf("%g", pbn))
      pbn = pbn + 1
    }
    #Final estimate is genetic liability times probability.
    reduced_atleast_2_siblings = reduced_atleast_2_siblings %>% 
      dplyr::mutate("post_gen_liab" = sapply((Map("*", est_per_sib, probs)), sum)) %>% 
      dplyr::select(-probs, -est_per_sib)

  }
  
  #combine results
  comb_ests = dplyr::bind_rows(reduced_max_1_sibling, reduced_atleast_2_siblings)
  #assign results to observed configurations
  phen = dplyr::left_join(phen, comb_ests, by = colnames(comb_ests)[-(ncol(comb_ests) - 0:1)])
  return(phen)
}