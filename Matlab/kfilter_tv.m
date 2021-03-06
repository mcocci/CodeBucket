function [ L, KF ] = kfilter(data, sysmats, s0, ss0, fullout)

% Kalman Filter programming that accommodates:
% 1. Missing Data: Must be marked by a NaN in the data matrix.  If so,
%    then the corresponding row in the measurement equation will be
%    removed for that time period. 
% 2. Time-Varying Matrices: We check up front for time variation in the
%    system matrices. We check all matrices for a third dimension
%    (assumed to index time) and pull use the relevant time t matrices.
%    All checks are done for the matrices individually, so you could
%    have a time-varying T, but a non-time-varying M, for example.
%
%    NOTE: A matrix in the t-th location (in the third dimension of the
%    array) is assumed to be the matrix that is relevant for the
%    transition equation that gets the state from time t-1 to t, or for
%    the measurement equation that relates y_t to s_t.
% 
% State Space Model Represention %
%   s_t = C + T*s_{t-1} + R*e_t (state or transition equation)
%   y_t = D + M*s_t + Q*eta_t   (observation or measurement equation)
%
% Function arguments:
%   data      (Ny x capT) matrix containing data (y(1),...,y(capT))'
%   sysmats   Struct that holds the system matrices. Must have fields
%     C       (Ns x 1) column vector representing the constant terms in
%             the transition equation
%     T       (Ns x Ns) transition matrix
%     R       (Ns x Ns) covariance matrix for exogenous shocks e_t in
%               the transition equation
%     D       (Ny x 1) vector for constant terms in the measurement
%               equation
%     M       (Ny x Ns) matrix for the measurement equation.
%     Q       (Ny x Ny) covariance matrix for the exogenous shocks eta_t
%               in the measurment equation
%   s0      (Nz x 1) initial state vector.
%   ss0     (Nz x Nz) covariance matrix for initial state vector
%   tv      A indicator for whether or not 1 or more matrices in the
%           state transition or measurement equation are time varying.
%   fullout Indicator for whether to return the full gamut of output
%           (notably information about the updating procedure)
%
% Automatic Output: Just the likelihood in the event that you are
% simplying mode finding.
%   L           Likelihood, provided that the errors are normally
%                 distributed
%
% Optional Output (if nargout > 1):
%   s_end       Final filtered state vector 
%   ss_end      Covariance matrix for the final filtered state vector
%   s_filt      (Ns x t) matrix consisting of the filtered states
%   ss_filt     (Ns x Ns x t) array consisting of the filtered
%                 covariance matrices
%   y_prederr   (Ny x t) matrix consisting of the prediction error %
%
% Optional Output (if nargout > 1 & fullout==1): Optional because they
% can be used to illustrate the updating procedure over time. But they
% aren't as important as the optional output above.
%
%   y_pred      (Ny x t) matrix consisting of the y_{t+1|t}
%   yy_pred     (Ny x Ny x t) array consisting of the covariance matrix
%                 for y_{t+1|t}
%   s_pred      (Ns x t) matrix consisting of the s_{t+1|t}
%   ss_pred     (Ns x Ns x t) matrix consisting of the covariance matrix
%                 for s_{t+1|t}
%
%   This is a M-file for MATLAB.
%   - This Kalman Filter code is adapted from that of the FRBNY DSGE
%     model code (September 2014, Liberty Street Economics). That, in
%     turn, built upon  kalcvf.m by Iskander Karibzhanov 5-28-02.
%   - Additions include a different characterization of the state
%     transition and measurement equations, plus a way to handle
%     time-varying matrices and a slightly different setup.
%
%=======================================================================

  %% Make sure you have all of the matrices you need
  matsnames = ['C'; 'T'; 'R'; 'D'; 'M'; 'Q'];
  matsmiss  = setdiff(matsnames, cell2mat(fieldnames(symats)));
  if ~isempty(matsmiss)
    matsmiss  = arrayfun(@(s) [s, ','], matsmiss, 'UniformOutput', false);
    error(['Missing matrices: ', sprintf('%s', matsmiss{:})]);
  end


  %% Basic parameters; determine sizing and loops; used often
  capT = size(data,2);
  Ns   = size(sysmats.C,1); % num states
  Ny   = size(sysmats.D,1); % num observables
  nout = nargout;

  %% Check input matrix dimensions
  if size(sysmats.C,2) ~= 1,  error('C must be column vector'); end
  if size(sysmats.D,2) ~= 1,  error('D must be column vector'); end
  if size(data,2) ~= Ny,      error('Data and D must imply the same number of observables'); end
  if size(sysmats.T,1) ~= Ns, error('T and C must imply the same number of states'); end

  if any(size(s0) ~= [Ns 1]),     error('s0 must be column vector of length Ns'); end
  if any(size(ss0,1) ~= [Ns Ns]), error('ss0 must be Ns x Ns matrix'); end

  if any([size(sysmats.T,1) size(sysmats.T,2)] ~= [Ns Ns]),  error('Transition matrix, T, must be square'); end
  if any([size(sysmats.M,1) size(sysmats.M,2)] ~= [Ny Ns]),  error('M must be Ny by Ns matrix'); end

  %% Check if mats/arrays are time-varying

    % number of elements along 3rd or t dimension
    tdim_els = arrayfun(@(mt) size(sysmats.(mt), 3), matsnames);

    % Which indices are time varying
    tv_inds = find(tdim_els > 1);

    % Check that 3D time-varying arrays have capT elements along 3rd dim
    too_small = intersect(find(tdim_els ~= capT), tv_inds);
    if ~isempty(too_small)
      err1 = ...
        sprintf(['The following matrices have a 3rd dimension, ' ...
                 'indicating time varying.\n However, they are not the ' ...
                 'right size, as size(mat, 3) ~= capT.\n']);
      err2 = sprintf('%s ', matsnames(too_small));
      error([err1 err2])
    end

  % Pre-Allocate matrices
  KF.s_filt    = nan(Ns, capT);
  KF.ss_filt   = nan(Ns, Ns, capT);
  KF.y_prederr = nan(Ny, capT);

  if fullout
    KF.s_pred  = nan(Ns, capT);
    KF.ss_pred = nan(Ns, Ns, capT);
    KF.y_pred  = nan(Ny, capT);
    KF.yy_pred = nan(Ny, Ny, capT);
  end

  % Set up initial state vector and cov matrix
  s  = s0;
  ss = ss0;
 
  % Log likelihood
  L = 0;

  % Set up anonymous function that can do assignment of the time t
  % values. This will be useful when we want to assign T_t (the time t
  % transition matrix) to the simpler name T. We do this because T*s is
  % way more readable than T(:,:,t)*s everywhere for all matrices in the
  % procedure; plus, now we don't have to set up 3D matrices for
  % non-time-varying stuff
  asgn = @(var,val,t) assignin('caller', var, val(:,:,t))
  
  for t = 1:capT

    % If time varying, assign out the time time t matrix
    for mt = tv_inds
      asgn(matsnames(mt), idx_t(sysmats.matsnames(mt)), t)
    end

    %% Handle missing observations
      
      % if an element of the vector y_t is missing (NaN) for
      % the observation t, the corresponding row is ditched
      % from the measurement equation.
      not_nan = ~isnan(data(:,t));
      Ny_t    = length(data_t);
      
      data_t  = data(not_nan,t);
      M_t     = M(not_nan,:); 
      Q_t     = Q(not_nan,not_nan);
      D_t     = D(not_nan);

    %% From Filtered to Forecast values
    s  = C + T*s;           % mu_{t|t} -> mu_{t+1|t}
    ss = T*ss*T' + R;       % Sigma_{t|t} -> Sigma_{t+1|t}
    y  = D_t + M_t*s;       % E_t[y_{t+1}]
    yy = M_t*ss*M_t' + Q_t; % Var_t[y_{t+1}]

    %% Save forecasts
    if fullout
      KF.s_pred(:,t)    = s;
      KF.ss_pred(:,:,t) = ss;
      KF.y_pred(:,t)    = D + M*s;     % <- Compute forecasts for all obs, 
      KF.yy_pred(:,:,t) = M*ss*M' + Q; % <- not just the non-missing ones
    end

    %% Evaluate the likelihood p(y_t | I_{t-1},C,T,Q,D,M,R)
    err = data_t - y;     
    L = L - 0.5*Ny_t*log(2*pi) - 0.5*log(det(yy)) ...
        - 0.5*err'*(yy\err);

    %% From Forecast to Filtered
    Mss = M_t*ss;           
    s   = s + Mss'*(yy\err); % mu_{t+1|t} -> mu_{t+1|t+1} 
    ss  = ss - Mss*(yy\Mss); % Sigma_{t+1|t} -> Sigma_{t+1|t+1}

    %% Save filtering information
    KF.y_prederr(:,t) = err;
    KF.s_filt(:,t)    = s;
    KF.ss_filt(:,:,t) = ss;
    
  end

  KF.L      = L;
  KF.s_end  = s;
  KF.ss_end = ss;


end  


