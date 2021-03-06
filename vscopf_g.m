function [h, g, dh, dg] = vscopf_g(x, om, mpopt)
%function [h,g,dh,dg] = pwind_consfcn(x, om, Ybus, Yf, Yt, mpopt, idxConstrainedLines, varargin)
%OPF_CONSFCN  Evaluates nonlinear constraints and their Jacobian for OPF.
%   [H, G, DH, DG] = OPF_CONSFCN(X, OM, YBUS, YF, YT, MPOPT, IL)
%
%   Constraint evaluation function for AC optimal power flow, suitable
%   for use with MIPS or FMINCON. Computes constraint vectors and their
%   gradients.
%
%   Inputs:
%     X : optimization vector
%     OM : OPF model object
%     YBUS : bus admittance matrix
%     YF : admittance matrix for "from" end of constrained branches
%     YT : admittance matrix for "to" end of constrained branches
%     MPOPT : MATPOWER options struct
%     IL : (optional) vector of branch indices corresponding to
%          branches with flow limits (all others are assumed to be
%          unconstrained). The default is [1:nl] (all branches).
%          YF and YT contain only the rows corresponding to IL.
%
%   Outputs:
%     H  : vector of inequality constraint values (flow limits)
%          where the flow can be apparent power, real power, or
%          current, depending on the value of opf.flow_lim in MPOPT
%          (only for constrained lines), normally expressed as
%          (limit^2 - flow^2), except when opf.flow_lim == 'P',
%          in which case it is simply (limit - flow).
%     G  : vector of equality constraint values (power balances)
%     DH : (optional) inequality constraint gradients, column j is
%          gradient of H(j)
%     DG : (optional) equality constraint gradients
%
%   Examples:
%       [h, g] = opf_consfcn(x, om, Ybus, Yf, Yt, mpopt);
%       [h, g, dh, dg] = opf_consfcn(x, om, Ybus, Yf, Yt, mpopt);
%       [h, g, dh, dg] = opf_consfcn(x, om, Ybus, Yf, Yt, mpopt, idxConstrainedLines);
%
%   See also OPF_COSTFCN, OPF_HESSFCN.

tic;
%% define named indices into data matrices
define_constants;

%% unpack data
mpc = get_mpc(om);
[baseMVA, bus, gen, branch,cs,gen2,bus2] = ...
    deal(mpc.baseMVA, mpc.bus, mpc.gen, mpc.branch,mpc.contingencies, mpc.gen2, mpc.bus2);
[Ybus, Yf, Yt, load] = deal(cs.Ybus, cs.Yf, cs.Yt, cs.load);
[vv, ~, nn] = get_idx(om);

lim_type = mpopt.opf.flow_lim; %% branch flow limit type
%% problem dimensions
nb = size(bus, 1);          %% number of buses
%nl = size(branch, 1);       %% number of branches
ng = size(gen, 1);          %% number of dispatchable injections
nxyz = length(x);           %% total number of control vars of all types
nc = cs.N; % includes base case

%% check if base case Pg are included as optimization variables
includePgBase = isfield(vv.i1,'Pg');
if includePgBase
    % check if curtailable generators are included
    fixBaseWind = (vv.N.Pg < ng); 
else
    fixBaseWind = 0;
end

    %% find constrained lines
        %% number of constrained lines
idxConstrainedLines = cs.constrainedActiveLines(:,1);
nConstrainedLines = cs.nConstrainedActiveLines(1);

%% preallocate return variables
g = zeros(2*nb*nc,1);
dg = zeros(length(g),nxyz);

if nConstrainedLines % prepare for line flow constraints
    if includePgBase % constraint for all cases
        nInequalityConstraints = 2*sum(cs.nConstrainedActiveLines);
    else % only constraints for contingencies
        nInequalityConstraints = 2*sum(cs.nConstrainedActiveLines(2:end));
    end
    h = zeros(nInequalityConstraints,1);
    dh = zeros(nInequalityConstraints,nxyz);
    %h = [];
    %dh = zeros(1,nxyz); %% add counter in setup_contingencies
else
    h = [];
    dh = [];
end

%% fixed indices
bolIdxPCur = gen2(:,PTYPE)==PCUR;
nPCurtail = sum(bolIdxPCur);
bolIdxPNotCur = not(bolIdxPCur);

%find buses in load increas area
varload_idx = find(bus2(:,LOAD_INCREASE_AREA));
busVarN = length(varload_idx);

bolIdxPVar = gen2(:,PTYPE)== PVAR;

bolIdxPFix = gen2(:,PTYPE) == PFIX;




nzcounter = 0; % count number of non-zero entries to make sure entries are not overwritten
ycounter = 0;
hcounter = 0; % counter for rows in h, dh
gcounter = 0;
for i=1:nc     % loop over all cases, including base case
    
    if i == 1 % base case
        sidx = '';
    else % contingency
        sidx = num2str(i);
    end
    
    %% Variable indices
    
    bolIdxPVarActive = and(cs.activeGenerators(:,i),bolIdxPVar);
    bolIdxActiveGen = cs.activeGenerators(:,i);
    bolIdxTrippedGen = ~cs.activeGenerators(:,i);
    
    %idxBolPFixActive = and(cs.activeGenerators(:,i),bolIdxPFix);
    nActiveLines = cs.nActiveLines(i);
    
    if ~fixBaseWind 
        idxPBaseOpt = find(and(bolIdxActiveGen,~bolIdxPVar));
    else
        idxPBaseOpt = find(and(bolIdxActiveGen,bolIdxPFix));
    end
    nPBaseOpt = length(idxPBaseOpt);
    
    %% unpack wind scenario
    iWind = cs.wind(1+(i-1)*nPCurtail:i*nPCurtail);
    
    % use admittance matrix for this contingency
    %% un-pack admittance matrix
    % NOTE: Admittance matrices for different contingencies stack in a
    % single column

    iYbus = Ybus(1+(i-1)*nb:i*nb,:);
    iYf = Yf(ycounter+1:ycounter+nActiveLines,:);
    iYt = Yt(ycounter+1:ycounter+nActiveLines,:);

    % pick out lines with active constraints out of lines active for this
    % contingency
    idxYbranch = idxConstrainedLines(cs.activeLines(:,i)); % indices for Yf and Yt
    idxBranch = and(idxConstrainedLines, cs.activeLines(:,i)); % indices for branch
    iiYf = iYf(idxYbranch,:);
    iiYt = iYt(idxYbranch,:);
    % Note: Yf and Yt contain only active lines for a given contingency
    % branch contains all lines

	
	%% index ranges
    
    iVa = vv.i1.(['Va' sidx]):vv.iN.(['Va' sidx]);
    iVm = vv.i1.(['Vm' sidx]):vv.iN.(['Vm' sidx]);
    if i > 1 || includePgBase
        iPg = vv.i1.(['Pg' sidx]):vv.iN.(['Pg' sidx]);
    else % for base case when it is excluded
        iPg = [];
    end
    iQg = vv.i1.(['Qg' sidx]):vv.iN.(['Qg' sidx]);
    
    if i > 1
        iBeta = vv.i1.(['Beta' sidx]):vv.iN.(['Beta' sidx]);
    else
        iBeta = [];
    end
    
    nMismatch = nn.N.(['Qmis' sidx]) + nn.N.(['Pmis' sidx]);
    if includePgBase || i > 1
        nBranchLimits = nn.N.(['Sf' sidx]) + nn.N.(['St' sidx]);
    else
       nBranchLimits = 0; 
    end
    
    Pg = x(iPg);
    Qg = x(iQg);
    Va = x(iVa);
    Vm = x(iVm);
    V = Vm .* exp(1j * Va);
    
	bus(varload_idx,[PD QD]) = load(1+(i-1)*busVarN:i*busVarN,:);
	
    %% enter current values
    if i == 1 % base case
        if includePgBase
            if ~fixBaseWind % all generators are optimization variables
                gen(:, PG) = Pg * baseMVA;  %% active generation in MW
            else % only non-curtailable generators are optimization variables
                gen(bolIdxPNotCur, PG) = Pg*baseMVA; % NOTE: idxPCurtail must be boolean
            end
        end
		gen(:, QG) = Qg * baseMVA;
    else
        %gen(pvar_idx,PG) = Pg * baseMVA;
		trippedGeneration = gen(bolIdxTrippedGen,[PG QG]); % store values for tripped generator
		gen(bolIdxTrippedGen,[PG QG]) = 0; % set tripped generator to zero
		
		gen(bolIdxPVarActive,PG) = Pg*baseMVA;
		gen(bolIdxActiveGen,QG) = Qg*baseMVA;
        % enter wind scenarios
        gen(bolIdxPCur,PG) = iWind.*(1-x(iBeta));
    end
	
    Sbus = makeSbus(baseMVA, bus, gen, mpopt, Vm);  %% net injected power in p.u.
    
    % evaluate power flow equations
    mis = V .* conj(iYbus * V) - Sbus;
    
    %g(1+(i-1)*2*nb:2*i*nb) = [real(mis); imag(mis)];
    g(gcounter+1:gcounter+nMismatch) = [real(mis); imag(mis)];

    
    if nConstrainedLines > 0 % then, the inequality constraints (branch flow limits)
        
        if includePgBase || i > 1
            
            flow_max = branch(idxBranch, RATE_A) / baseMVA;
            if lim_type ~= 'P'        %% typically use square of flow
                flow_max = flow_max.^2;
            end
            
            if lim_type == 'I'    %% current magnitude limit, |I|
                If = iiYf * V;
                It = iiYt * V;
                
                h(hcounter+1:hcounter+nBranchLimits,1) = ...
                    [ If .* conj(If) - flow_max;    %% branch current limits (from bus)
                    It .* conj(It) - flow_max ];  %% branch current limits (to bus)
            else
                %% compute branch power flows
                Sf = V(branch(idxBranch, F_BUS)) .* conj(iiYf * V);  %% complex power injected at "from" bus (p.u.)
                St = V(branch(idxBranch, T_BUS)) .* conj(iiYt * V);  %% complex power injected at "to" bus (p.u.)
                
                if lim_type == 'P'                      %% active power limit, P
                    h(hcounter+1:hcounter+nBranchLimits,1) = ...
                        [ real(Sf) - flow_max;                %% branch real power limits (from bus)
                        real(St) - flow_max ];              %% branch real power limits (to bus
                else                                        %% apparent power limit, |S|
                    h(hcounter+1:hcounter+nBranchLimits,1) = ...
                        [ Sf .* conj(Sf) - flow_max;          %% branch apparent power limits (from bus)
                        St .* conj(St) - flow_max ];        %% branch apparent power limits (to bus)
                end
            end
        end
    end
    
    %%----- evaluate partials of constraints -----
    if nargout > 2
        
        %% JACOBIAN FOR POWER BALANCE
        
        %nVar = vv.N.(['Pg' sidx]) + vv.N.(['Qg' sidx]) + vv.N.(['Vm' sidx]) + vv.N.(['Va' sidx]);
        
        %% compute partials of injected bus powers
        [dSbus_dVm, dSbus_dVa] = dSbus_dV(iYbus, V);           %% w.r.t. V
        [~, neg_dSd_dVm] = makeSbus(baseMVA, bus, gen, mpopt, Vm); % for voltage dependent loads
        dSbus_dVm = dSbus_dVm - neg_dSd_dVm;
        
        %% dPi/dPg
        if i == 1 % base case
            if includePgBase % include Pg for base case as optimization variables (all Pg)
                
                nPg = vv.N.(['Pg' sidx]);
                neg_CgP = zeros(nb, nPg);
                if ~fixBaseWind
                    neg_CgP(sub2ind(size(neg_CgP),gen(:,GEN_BUS)',1:nPg)) = -1;
                else
                    neg_CgP(sub2ind(size(neg_CgP),gen(bolIdxPNotCur,GEN_BUS)',1:nPg)) = -1;
                end
            else % base case Pg taken as parameters
                nPg = 0;
                neg_CgP = zeros(nb,nPg);
            end
            %% dPi/dBeta
            dPdBeta = zeros(nb,length(iBeta));
            %neg_CgP = sparse(gen(:, GEN_BUS), 1:PgcN, -1, nb, PgcN);   %% Pbus w.r.t. Pg
        else % contingency cases, must always be one Pg which can be changed
            nPg = vv.N.(['Pg' sidx]);
            neg_CgP = zeros(nb, nPg);
            neg_CgP(sub2ind(size(neg_CgP),gen(bolIdxPVarActive,GEN_BUS)',1:nPg)) = -1;
            %neg_CgP = sparse(gen(pvar_idx, GEN_BUS), 1:PgcN, -1, nb, PgcN);
            dPdBeta = zeros(nb,nPCurtail);
            dPdBeta( sub2ind( size(dPdBeta),gen(bolIdxPCur,GEN_BUS)',1:size(dPdBeta,2) ) ) = iWind/baseMVA;
            %dQdBeta = zeros(nb,nPCurtail)
        end
        %% dQi/dQg
        nQg = vv.N.(['Qg' sidx]);
        neg_CgQ = zeros(nb, nQg);
        neg_CgQ(sub2ind([nb nQg],gen(bolIdxActiveGen,GEN_BUS)',1:nQg)) = -1;
        %neg_CgQ = sparse(gen(idxActiveGenerators,GEN_BUS), 1:ng,-1,nb,ng); %% Qbus w.r.t. Qg
        dQdBeta = zeros(nb,length(iBeta));
        %% construct Jacobian of equality (power flow) constraints and transpose it
        dg(1+2*nb*(i-1):2*nb*i, [iVa iVm iPg iQg iBeta]) = [
            real([dSbus_dVa dSbus_dVm]) neg_CgP zeros(nb, nQg) dPdBeta;  %% P mismatch w.r.t Va, Vm, Pg, Qg
            imag([dSbus_dVa dSbus_dVm]) zeros(nb, nPg) neg_CgQ dQdBeta;  %% Q mismatch w.r.t Va, Vm, Pg, Qg
            ];
        
        if nPg < ng && includePgBase %% dPi/dPg(base case) for contingency cases
            dg(sub2ind(size(dg),gen(idxPBaseOpt,GEN_BUS)+2*nb*(i-1),idxPBaseOpt+vv.i1.Pg-1)) = - ones(1, nPBaseOpt);
        end

        
        %% JACOBIAN FOR BRANCH LIMITS
        if nConstrainedLines > 0
            % NOTE: Branch flows independent of injected powers, hence no
            % modification of Jacobian necessary
            if includePgBase || i > 1
                %% compute partials of Flows w.r.t. V
                if lim_type == 'I'                      %% current
                    [dFf_dVa, dFf_dVm, dFt_dVa, dFt_dVm, Ff, Ft] = dIbr_dV(branch(idxBranch,:), iiYf, iiYt, V);
                else                                    %% power
                    [dFf_dVa, dFf_dVm, dFt_dVa, dFt_dVm, Ff, Ft] = dSbr_dV(branch(idxBranch,:), iiYf, iiYt, V);
                end
                if lim_type == 'P' || lim_type == '2'   %% real part of flow (active power)
                    dFf_dVa = real(dFf_dVa);
                    dFf_dVm = real(dFf_dVm);
                    dFt_dVa = real(dFt_dVa);
                    dFt_dVm = real(dFt_dVm);
                    Ff = real(Ff);
                    Ft = real(Ft);
                end
                
                if lim_type == 'P'
                    %% active power
                    [df_dVa, df_dVm, dt_dVa, dt_dVm] = deal(dFf_dVa, dFf_dVm, dFt_dVa, dFt_dVm);
                else
                    %% squared magnitude of flow (of complex power or current, or real power)
                    [df_dVa, df_dVm, dt_dVa, dt_dVm] = ...
                        dAbr_dV(dFf_dVa, dFf_dVm, dFt_dVa, dFt_dVm, Ff, Ft);
                end
                
                %% construct Jacobian of inequality (branch flow) constraints & transpose
                %dh = sparse(2*nConstrainedLines, nxyz);
                dh(hcounter+1:hcounter+nBranchLimits, [iVa iVm]) = [
                    df_dVa df_dVm;                     %% "from" flow limit
                    dt_dVa dt_dVm;                     %% "to" flow limit
                    ];
                dh_nzeros = nnz(dh);
                assert(dh_nzeros == nzcounter + nnz(df_dVa) + nnz(df_dVm) + nnz(dt_dVa) + nnz(dt_dVm),...
                    'Entries overwritten in dh');
                nzcounter = dh_nzeros;
            end
        end
    end
	
	% restore tripped generation
	if i > 1
		gen(bolIdxTrippedGen,[PG QG]) = trippedGeneration;
	end
	
	% increase counters
    gcounter = gcounter + nMismatch;
    hcounter = hcounter + nBranchLimits;
    ycounter = ycounter + nActiveLines;
end
% transpose jacobians
dg = dg';
dh = dh';
%display(num2str(looptime))