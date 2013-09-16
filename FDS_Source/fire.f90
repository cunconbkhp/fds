MODULE FIRE
 
! Compute combustion
 
USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: SECOND
 
IMPLICIT NONE
PRIVATE
   
CHARACTER(255), PARAMETER :: fireid='$Id$'
CHARACTER(255), PARAMETER :: firerev='$Revision$'
CHARACTER(255), PARAMETER :: firedate='$Date$'

TYPE(REACTION_TYPE), POINTER :: RN=>NULL()
REAL(EB) :: Q_UPPER

PUBLIC COMBUSTION, GET_REV_fire

CONTAINS
 
SUBROUTINE COMBUSTION(NM)

INTEGER, INTENT(IN) :: NM
REAL(EB) :: TNOW

IF (EVACUATION_ONLY(NM)) RETURN

TNOW=SECOND()

IF (INIT_HRRPUV) RETURN

CALL POINT_TO_MESH(NM)

! Upper bounds on local HRR per unit volume

Q_UPPER = HRRPUA_SHEET/CELL_SIZE + HRRPUV_AVERAGE

! Call combustion ODE solver

CALL COMBUSTION_GENERAL

TUSED(10,NM)=TUSED(10,NM)+SECOND()-TNOW

END SUBROUTINE COMBUSTION


SUBROUTINE COMBUSTION_GENERAL

! Generic combustion routine for multi-step reactions

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL,GET_SPECIFIC_HEAT,GET_MOLECULAR_WEIGHT, &
                              GET_SENSIBLE_ENTHALPY_DIFF,GET_SENSIBLE_ENTHALPY
INTEGER :: I,J,K,NS,NR,II,JJ,KK,IIG,JJG,KKG,IW,N
REAL(EB):: ZZ_GET(0:N_TRACKED_SPECIES),ZZ_MIN=1.E-10_EB,DZZ(0:N_TRACKED_SPECIES),CP,HDIFF
LOGICAL :: DO_REACTION,REACTANTS_PRESENT,Q_EXISTS
TYPE (REACTION_TYPE), POINTER :: RN
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM,SM0

Q          = 0._EB
D_REACTION = 0._EB
Q_EXISTS = .FALSE.
SM0 => SPECIES_MIXTURE(0)

!$OMP PARALLEL DEFAULT(NONE) &
!$OMP SHARED(KBAR,JBAR,IBAR,SOLID,CELL_INDEX,N_TRACKED_SPECIES,N_REACTIONS,REACTION,COMBUSTION_ODE,Q,RSUM,TMP,PBAR, &
!$OMP        PRESSURE_ZONE,RHO,ZZ,D_REACTION,SPECIES_MIXTURE,SM0,DT,CONSTANT_SPECIFIC_HEAT)

!$OMP DO SCHEDULE(STATIC) COLLAPSE(3)&
!$OMP PRIVATE(K,J,I,ZZ_GET,DO_REACTION,NR,RN,REACTANTS_PRESENT,ZZ_MIN,Q_EXISTS,SM,CP,HDIFF,DZZ)

DO K=1,KBAR
   DO J=1,JBAR
      ILOOP: DO I=1,IBAR
         !Check to see if a reaction is possible
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ILOOP
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         ZZ_GET(0) = 1._EB - MIN(1._EB,SUM(ZZ_GET(1:N_TRACKED_SPECIES)))
         DO_REACTION = .FALSE.
         REACTION_LOOP: DO NR=1,N_REACTIONS
            RN=>REACTION(NR)
            REACTANTS_PRESENT = .TRUE.
               DO NS=0,N_TRACKED_SPECIES
                  IF (RN%NU(NS)<0._EB .AND. ZZ_GET(NS) < ZZ_MIN) THEN
                     REACTANTS_PRESENT = .FALSE.
                     EXIT
                  ENDIF
               END DO
             DO_REACTION = REACTANTS_PRESENT
             IF (DO_REACTION) EXIT REACTION_LOOP
         END DO REACTION_LOOP
         IF (.NOT. DO_REACTION) CYCLE ILOOP
         DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) ! store old ZZ for divergence term
         ! Call combustion integration routine
         CALL COMBUSTION_MODEL(I,J,K,ZZ_GET,Q(I,J,K))
         ! Update RSUM and ZZ
         Q_IF: IF (ABS(Q(I,J,K)) > TWO_EPSILON_EB) THEN
            Q_EXISTS = .TRUE.
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K)) 
            TMP(I,J,K) = PBAR(K,PRESSURE_ZONE(I,J,K))/(RSUM(I,J,K)*RHO(I,J,K))
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES)
            CP_IF: IF (.NOT.CONSTANT_SPECIFIC_HEAT) THEN
               ! Divergence term
               DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) - DZZ(1:N_TRACKED_SPECIES)
               CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP(I,J,K))
               DO N=1,N_TRACKED_SPECIES
                  SM => SPECIES_MIXTURE(N)
                  CALL GET_SENSIBLE_ENTHALPY_DIFF(N,TMP(I,J,K),HDIFF)
                  D_REACTION(I,J,K) = D_REACTION(I,J,K) + ( (SM%RCON-SM0%RCON)/RSUM(I,J,K) - HDIFF/(CP*TMP(I,J,K)) )*DZZ(N)/DT
               ENDDO
            ENDIF CP_IF
         ENDIF Q_IF
      ENDDO ILOOP
   ENDDO
ENDDO
!$OMP END DO
!$OMP END PARALLEL

IF (.NOT.Q_EXISTS) RETURN

! Set Q in the ghost cell, just for better visualization.

DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (WALL(IW)%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY .AND. WALL(IW)%BOUNDARY_TYPE/=OPEN_BOUNDARY) CYCLE
   II  = WALL(IW)%ONE_D%II
   JJ  = WALL(IW)%ONE_D%JJ
   KK  = WALL(IW)%ONE_D%KK
   IIG = WALL(IW)%ONE_D%IIG
   JJG = WALL(IW)%ONE_D%JJG
   KKG = WALL(IW)%ONE_D%KKG
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO

END SUBROUTINE COMBUSTION_GENERAL


SUBROUTINE COMBUSTION_MODEL(I,J,K,ZZ_GET,Q_OUT)
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
USE PHYSICAL_FUNCTIONS, ONLY: LES_FILTER_WIDTH_FUNCTION,GET_AVERAGE_SPECIFIC_HEAT,GET_SPECIFIC_GAS_CONSTANT
USE RADCONS, ONLY: RADIATIVE_FRACTION
INTEGER, INTENT(IN) :: I,J,K
REAL(EB), INTENT(OUT) :: Q_OUT
REAL(EB), INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: ERR_EST,ERR_TOL,ZZ_TEMP(0:N_TRACKED_SPECIES),&
            A1(0:N_TRACKED_SPECIES),A2(0:N_TRACKED_SPECIES),A4(0:N_TRACKED_SPECIES),Q_SUM,Q_CALC,&
            DT_SUB,DT_SUB_NEW,DT_ITER,ZZ_STORE(0:N_TRACKED_SPECIES,0:3),TV(0:2,0:N_TRACKED_SPECIES),CELL_VOLUME,CELL_MASS,&
            ZZ_DIFF(0:2,0:N_TRACKED_SPECIES),ZZ_MIXED(0:N_TRACKED_SPECIES),ZZ_GET_0(0:N_TRACKED_SPECIES),ZETA0,ZETA,ZETA1,&
            SMIX_MIX_MASS_0(0:N_TRACKED_SPECIES),SMIX_MIX_MASS(0:N_TRACKED_SPECIES),TOTAL_MIX_MASS,&
            TAU_D,TAU_G,TAU_U,DELTA,TMP_MIXED_ZONE,DT_SUB_MIN,RHO_HAT
REAL(EB), PARAMETER :: ZZ_MIN=1.E-10_EB
INTEGER :: NR,NS,ITER,TVI,RICH_ITER,TIME_ITER,SR
INTEGER, PARAMETER :: TV_ITER_MIN=5,RICH_ITER_MAX=5
LOGICAL :: EXTINCT(1:N_REACTIONS),TV_FLUCT(0:N_TRACKED_SPECIES)
TYPE(REACTION_TYPE), POINTER :: RN=>NULL()

IF (FIXED_MIX_TIME>0._EB) THEN
   MIX_TIME(I,J,K)=FIXED_MIX_TIME
ELSE
   DELTA = LES_FILTER_WIDTH_FUNCTION(DX(I),DY(J),DZ(K))
   TAU_D=0._EB
   DO NR =1,N_REACTIONS
      RN => REACTION(NR)
      TAU_D = MAX(TAU_D,D_Z(MIN(4999,NINT(TMP(I,J,K))),RN%FUEL_SMIX_INDEX))
   ENDDO
   TAU_D = DELTA**2/TAU_D ! FDS Tech Guide (5.21)
   IF (LES) THEN
      TAU_U = C_DEARDORFF*SC*RHO(I,J,K)*DELTA**2/MU(I,J,K)            ! FDS Tech Guide (5.22)
      TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB))                      ! FDS Tech Guide (5.23)
      MIX_TIME(I,J,K)= MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME)) ! FDS Tech Guide (5.20)
   ELSE
      MIX_TIME(I,J,K)= MAX(TAU_CHEM,TAU_D)
   ENDIF
ENDIF

DT_SUB_MIN = DT/REAL(MAX_CHEMISTRY_ITERATIONS,EB)
ZZ_STORE(:,:) = 0._EB
Q_OUT = 0._EB
Q_CALC = 0._EB
Q_SUM = 0._EB
ITER= 0
DT_ITER = 0._EB
DT_SUB = DT 
DT_SUB_NEW = DT
EXTINCT(:) = .FALSE.
ZZ_GET_0 = ZZ_GET
ZZ_TEMP = ZZ_GET
ZZ_MIXED = ZZ_GET
ZETA0 = INITIAL_UNMIXED_FRACTION
ZETA  = ZETA0
ZETA1 = ZETA0
CELL_VOLUME = DX(I)*DY(J)*DZ(K)
CELL_MASS = RHO(I,J,K)*CELL_VOLUME
TOTAL_MIX_MASS = (1._EB-ZETA0)*CELL_MASS
SMIX_MIX_MASS_0 = ZZ_GET*TOTAL_MIX_MASS
SMIX_MIX_MASS = SMIX_MIX_MASS_0
RHO_HAT = RHO(I,J,K)
TMP_MIXED_ZONE = TMP(I,J,K)
   
INTEGRATION_LOOP: DO TIME_ITER = 1,MAX_CHEMISTRY_ITERATIONS

   ZETA1 = ZETA0*EXP(-(DT_ITER+DT_SUB)/MIX_TIME(I,J,K)) ! FDS Tech Guide (5.29)
   SMIX_MIX_MASS = MAX(0._EB,SMIX_MIX_MASS_0 + (ZETA-ZETA1)*CELL_MASS*ZZ_GET_0)
   TOTAL_MIX_MASS = SUM(SMIX_MIX_MASS)
   ZZ_MIXED = SMIX_MIX_MASS/(TOTAL_MIX_MASS) ! FDS Tech Guide (5.35)

   IF (SUPPRESSION .AND. TIME_ITER == 1) CALL EXTINCTION(ZZ_MIXED,TMP_MIXED_ZONE,EXTINCT) 

   INTEGRATOR_SELECT: SELECT CASE (COMBUSTION_ODE)

      CASE (EXPLICIT_EULER) ! Simple chemistry

         DO SR=0,N_SERIES_REACTIONS
            ZZ_MIXED = FUNC_FE(ZZ_MIXED,DT_SUB,TMP_MIXED_ZONE,EXTINCT,RHO_HAT,SR)
         ENDDO 
         IF (TIME_ITER > 1) CALL SHUTDOWN('ERROR: Error in Simple Chemistry')

      CASE (RK2_RICHARDSON) ! Finite-rate (or mixed finite-rate/fast) chemistry

         ERR_TOL = RICHARDSON_ERROR_TOLERANCE
         RICH_EX_LOOP: DO RICH_ITER =1,RICH_ITER_MAX
            DT_SUB = MIN(DT_SUB_NEW,DT-DT_ITER)

            A1 = FUNC_A(ZZ_MIXED,DT_SUB,1,TMP_MIXED_ZONE,EXTINCT,RHO_HAT) ! FDS Tech Guide (E.3)
            A2 = FUNC_A(ZZ_MIXED,DT_SUB,2,TMP_MIXED_ZONE,EXTINCT,RHO_HAT) ! FDS Tech Guide (E.4)
            A4 = FUNC_A(ZZ_MIXED,DT_SUB,4,TMP_MIXED_ZONE,EXTINCT,RHO_HAT)

            ! Species Error Analysis
            ERR_EST = MAXVAL(ABS((4._EB*A4-5._EB*A2+A1)))/45._EB ! FDS Tech Guide (E.7)
            DT_SUB_NEW = MIN(MAX(DT_SUB*(ERR_TOL/(ERR_EST+TWO_EPSILON_EB))**(0.25_EB),DT_SUB_MIN),DT-DT_ITER) ! (E.8)
            IF (RICH_ITER == RICH_ITER_MAX) EXIT RICH_EX_LOOP
            IF (ERR_EST <= ERR_TOL) EXIT RICH_EX_LOOP
            ZETA1 = ZETA0*EXP(-(DT_ITER+DT_SUB_NEW)/MIX_TIME(I,J,K))
            SMIX_MIX_MASS =  MAX(0._EB,SMIX_MIX_MASS_0 + (ZETA-ZETA1)*CELL_MASS*ZZ_GET_0)
            TOTAL_MIX_MASS = SUM(SMIX_MIX_MASS)
            ZZ_MIXED = SMIX_MIX_MASS/TOTAL_MIX_MASS
         ENDDO RICH_EX_LOOP
         ZZ_MIXED = (4._EB*A4-A2)*ONTH ! FDS Tech Guide (E.6)

   END SELECT INTEGRATOR_SELECT

   DT_ITER = DT_ITER + DT_SUB
   ITER = ITER + 1
   IF (OUTPUT_CHEM_IT) THEN
      CHEM_SUBIT(I,J,K) = ITER
   ENDIF
   ZZ_GET =  ZETA1*ZZ_GET_0 + (1._EB-ZETA1)*ZZ_MIXED ! FDS Tech Guide (5.30)

   ! Compute heat release rate
   
   Q_SUM = 0._EB
   IF (MAXVAL(ABS(ZZ_GET-ZZ_TEMP)) > ZZ_MIN) THEN
      Q_SUM = Q_SUM - RHO(I,J,K)*SUM(SPECIES_MIXTURE%H_F*(ZZ_GET-ZZ_TEMP)) ! FDS Tech Guide (5.14)
   ENDIF
   IF (Q_CALC + Q_SUM > Q_UPPER*DT) THEN
      Q_OUT = Q_UPPER
      ZZ_GET = ZZ_TEMP + (Q_UPPER*DT/(Q_CALC + Q_SUM))*(ZZ_GET-ZZ_TEMP)
      EXIT INTEGRATION_LOOP
   ELSE
      Q_CALC = Q_CALC+Q_SUM
      Q_OUT = Q_CALC/DT
   ENDIF
   
   ! Total Variation (TV) scheme (accelerates integration for finite-rate equilibrium calculations)
   ! See FDS Tech Guide Appendix E
   
   IF (COMBUSTION_ODE==RK2_RICHARDSON .AND. N_REACTIONS > 1) THEN
      DO NS = 0,N_TRACKED_SPECIES
         DO TVI = 0,2
            ZZ_STORE(NS,TVI)=ZZ_STORE(NS,TVI+1)
         ENDDO
         ZZ_STORE(NS,3) = ZZ_GET(NS)
      ENDDO
      TV_FLUCT(:) = .FALSE.
      IF (ITER >= TV_ITER_MIN) THEN
         SPECIES_LOOP_TV: DO NS = 0,N_TRACKED_SPECIES
            DO TVI = 0,2
               TV(TVI,NS) = ABS(ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI))
               ZZ_DIFF(TVI,NS) = ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI)
            ENDDO
            IF (SUM(TV(:,NS)) < ERR_TOL .OR. SUM(TV(:,NS)) >= ABS(2.9_EB*SUM(ZZ_DIFF(:,NS)))) THEN
               TV_FLUCT(NS) = .TRUE.
            ENDIF
            IF (ALL(TV_FLUCT)) EXIT INTEGRATION_LOOP
         ENDDO SPECIES_LOOP_TV
      ENDIF
   ENDIF

   ZZ_TEMP = ZZ_GET
   SMIX_MIX_MASS_0 = ZZ_MIXED*TOTAL_MIX_MASS
   ZETA = ZETA1
   IF ( DT_ITER > (DT-TWO_EPSILON_EB) ) EXIT INTEGRATION_LOOP

ENDDO INTEGRATION_LOOP

IF (REAC_SOURCE_CHECK) REAC_SOURCE_TERM(I,J,K,:) = (ZZ_GET_0-ZZ_GET)*CELL_MASS/DT ! store special output quantity

END SUBROUTINE COMBUSTION_MODEL


FUNCTION FUNC_FE(ZZ_IN,DT_LOC,TMP_MIXED_ZONE,EXTINCT,RHO_HAT,SR)
USE COMP_FUNCTIONS, ONLY:SHUTDOWN

REAL(EB), INTENT(IN) :: RHO_HAT,TMP_MIXED_ZONE
INTEGER, INTENT(IN) :: SR
LOGICAL, INTENT(IN) :: EXTINCT(1:N_REACTIONS)

REAL(EB), INTENT(IN) :: ZZ_IN(0:N_TRACKED_SPECIES), DT_LOC
REAL(EB) :: FUNC_FE(0:N_TRACKED_SPECIES),ZZ_0(0:N_TRACKED_SPECIES)
INTEGER :: NR,NS
REAL(EB) :: ZZ_NEW(0:N_TRACKED_SPECIES),DZZDT(0:N_TRACKED_SPECIES),DZZDT_TEMP(0:N_TRACKED_SPECIES),RATE_CONSTANT(1:N_REACTIONS)
TYPE(REACTION_TYPE), POINTER :: RN=>NULL()

ZZ_0 = ZZ_IN
ZZ_0(0) = 1._EB - MIN(1._EB,SUM(ZZ_0(1:N_TRACKED_SPECIES)))

DZZDT = 0._EB
RATE_CONSTANT = 0._EB

CALL COMPUTE_RATE_CONSTANT(RATE_CONSTANT,ZZ_0,RHO_HAT,DT_LOC,TMP_MIXED_ZONE,EXTINCT)

REACTION_LOOP: DO NR = 1,N_REACTIONS

   RN => REACTION(NR)
   IF (.NOT.RN%SERIES_REACTION .AND. SR < N_SERIES_REACTIONS) CYCLE REACTION_LOOP

   DZZDT_TEMP = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
   ZZ_NEW = ZZ_0 + DT_LOC*DZZDT_TEMP ! test Forward Euler step for each reaction
   
   ! Realizable individual reaction rates
   DO NS=0,N_TRACKED_SPECIES

      ! Note: Only reactants (RN%NU_MW_O_MW_F(NS)<0) of NR can go < 0
      IF (ZZ_NEW(NS) < 0._EB) RATE_CONSTANT(NR) = MIN(RATE_CONSTANT(NR),(0._EB-ZZ_0(NS))/(RN%NU_MW_O_MW_F(NS)*DT_LOC))
      
      ! Note: Only products  (RN%NU_MW_O_MW_F(NS)>0) of NR can go > 1
      IF (ZZ_NEW(NS) > 1._EB) RATE_CONSTANT(NR) = MIN(RATE_CONSTANT(NR),(1._EB-ZZ_0(NS))/(RN%NU_MW_O_MW_F(NS)*DT_LOC))

   ENDDO
   DZZDT_TEMP = RN%NU_MW_O_MW_F*RATE_CONSTANT(NR)
   DZZDT = DZZDT+DZZDT_TEMP ! summation of reaction rates

ENDDO REACTION_LOOP

ZZ_NEW = ZZ_0 + DT_LOC*DZZDT ! corrected FE step for all species

! Enforce realizability on mass fractions
! Note: The correction below may provide inaccurate results if the above realizability correction
! is not implemented on the individual reaction rates.

ZZ_NEW = ZZ_NEW - MIN(0._EB,MINVAL(ZZ_NEW)) ! shift ZZ_NEW such that min is >= 0
ZZ_NEW = ZZ_NEW / MAX(1._EB,SUM(ZZ_NEW))    ! now compress such that max is <= 1

ZZ_NEW(0) = 1._EB - MIN(1._EB,SUM(ZZ_NEW(1:N_TRACKED_SPECIES)))
FUNC_FE = ZZ_NEW

END FUNCTION FUNC_FE


FUNCTION FUNC_A(ZZ_IN,DT_SUB,N_INC,TMP_MIXED_ZONE,EXTINCT,RHO_HAT)
! This function uses RK2 to integrate ZZ_O from t=0 to t=DT_SUB in increments of DT_LOC=DT_SUB/N_INC

REAL(EB) :: FUNC_A(0:N_TRACKED_SPECIES)
REAL(EB), INTENT(IN) :: ZZ_IN(0:N_TRACKED_SPECIES),DT_SUB,TMP_MIXED_ZONE,RHO_HAT
INTEGER, INTENT(IN) :: N_INC
LOGICAL, INTENT(IN) :: EXTINCT(1:N_REACTIONS)
REAL(EB) :: DT_LOC,ZZ_0(0:N_TRACKED_SPECIES),ZZ_1(0:N_TRACKED_SPECIES),ZZ_2(0:N_TRACKED_SPECIES)
INTEGER :: N,SR

DT_LOC = DT_SUB/REAL(N_INC,EB)
ZZ_0=ZZ_IN

DO N=1,N_INC
   DO SR=0,N_SERIES_REACTIONS ! repeat for the number of series reactions
      ZZ_1 = FUNC_FE(ZZ_0,DT_LOC,TMP_MIXED_ZONE,EXTINCT,RHO_HAT,SR)
      ZZ_2 = FUNC_FE(ZZ_1,DT_LOC,TMP_MIXED_ZONE,EXTINCT,RHO_HAT,SR)
      FUNC_A = 0.5_EB*(ZZ_0 + ZZ_2)
      ZZ_0 = FUNC_A
   ENDDO
ENDDO

END FUNCTION FUNC_A


RECURSIVE SUBROUTINE COMPUTE_RATE_CONSTANT(RATE_CONSTANT,ZZ_MIXED_IN,RHO_HAT,DT_SUB,TMP_MIXED_ZONE,EXTINCT)
USE PHYSICAL_FUNCTIONS, ONLY : GET_MASS_FRACTION_ALL,GET_SPECIFIC_GAS_CONSTANT,GET_GIBBS_FREE_ENERGY
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
REAL(EB), INTENT(IN) :: ZZ_MIXED_IN(0:N_TRACKED_SPECIES),RHO_HAT,DT_SUB,TMP_MIXED_ZONE
LOGICAL, INTENT(IN) :: EXTINCT(1:N_REACTIONS)
REAL(EB), INTENT(INOUT) :: RATE_CONSTANT(1:N_REACTIONS)
REAL(EB) :: YY_PRIMITIVE(1:N_SPECIES),DZ_F(1:N_REACTIONS),DZ_FR(1:N_REACTIONS),DZ_FRAC_F(1:N_REACTIONS),&
            MASS_OX,MASS_OX_STOICH,ZZ_MIXED_FR(0:N_TRACKED_SPECIES),GFE,DZ_F_SUM
REAL(EB), PARAMETER :: ZZ_MIN=1.E-10_EB
INTEGER :: NS,NR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

ZZ_MIXED_FR = ZZ_MIXED_IN
MASS_OX = 0._EB
MASS_OX_STOICH = 0._EB
DZ_F(:) = 0._EB
DZ_FR(:) = 0._EB
DZ_F_SUM = 0._EB
DZ_FRAC_F(:) = 0._EB

DO NR = 1,N_REACTIONS
   RN => REACTION(NR)
   IF(RN%REVERSE) THEN ! compute equilibrium constant
      CALL GET_GIBBS_FREE_ENERGY(RN%NU,GFE,TMP_MIXED_ZONE)
      RN%EQBM_CONS = EXP(-1.E6_EB*GFE/(R0*TMP_MIXED_ZONE))
   ENDIF
   IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB) THEN
      DO NS = 0,N_TRACKED_SPECIES ! calculate oxygen
         IF (RN%NU(NS) < 0._EB .AND. NS /= RN%FUEL_SMIX_INDEX) THEN
            MASS_OX_STOICH = MASS_OX_STOICH + ABS(ZZ_MIXED_IN(RN%FUEL_SMIX_INDEX)*RN%NU_MW_O_MW_F(NS)) !Stoich mass O2
            MASS_OX = ZZ_MIXED_IN(NS) ! Mass O2 in cell
         ENDIF
      ENDDO
   ENDIF
ENDDO

IF (ALL(REACTION(:)%FAST_CHEMISTRY) .AND. ALL(EXTINCT)) THEN
   RATE_CONSTANT(:) = 0._EB
ELSE   
   IF (N_REACTIONS > 1) THEN
      DO NR = 1,N_REACTIONS
         RN => REACTION(NR)
         IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB .AND. .NOT. EXTINCT(NR)) THEN
            DO NS = 0,N_TRACKED_SPECIES
               IF (RN%NU(NS) < 0._EB) ZZ_MIXED_FR(NS) = ZZ_MIXED_FR(NS) - ABS(ZZ_MIXED_IN(NS)/RN%NU_MW_O_MW_F(NS))
               ZZ_MIXED_FR(NS) = MAX(0._EB,ZZ_MIXED_FR(NS))
            ENDDO
         ENDIF
      ENDDO
   ENDIF
   DO NR = 1,N_REACTIONS
      RN => REACTION(NR)
      IF (.NOT. RN%FAST_CHEMISTRY) THEN ! finite rate reactions
         CALL GET_MASS_FRACTION_ALL(ZZ_MIXED_FR,YY_PRIMITIVE)
         DZ_FR(NR) = RN%A*EXP(-RN%E/(R0*TMP_MIXED_ZONE))*RHO_HAT**RN%RHO_EXPONENT
         IF (ABS(RN%N_T)>TWO_EPSILON_EB) DZ_FR(NR)=DZ_FR(NR)*TMP_MIXED_ZONE**RN%N_T
         IF (ALL(RN%N_S<-998._EB)) THEN
            DO NS=0,N_TRACKED_SPECIES
               IF(RN%NU(NS) < 0._EB .AND. ZZ_MIXED_FR(NS) < ZZ_MIN) THEN
                  DZ_FR(NR) = 0._EB
               ENDIF
            ENDDO
         ELSE
            DO NS=1,N_SPECIES
               IF(ABS(RN%N_S(NS)) <= TWO_EPSILON_EB) CYCLE
               IF(RN%N_S(NS)>= -998._EB) THEN
                  IF (YY_PRIMITIVE(NS) < ZZ_MIN) THEN
                     DZ_FR(NR) = 0._EB
                  ELSE
                     DZ_FR(NR) = YY_PRIMITIVE(NS)**RN%N_S(NS)*DZ_FR(NR)
                  ENDIF
               ENDIF
            ENDDO
         ENDIF
         DO NS = 0,N_TRACKED_SPECIES
            IF (RN%NU(NS) < 0._EB) THEN
               DZ_FR(NR) =(1._EB/RN%EQBM_CONS)*DZ_FR(NR)
            ENDIF
         ENDDO
      ELSE ! fast chemistry
         DZ_F(NR) = 1.E10_EB
         DO NS = 0,N_TRACKED_SPECIES
            IF (RN%NU(NS) < 0._EB) THEN
               DZ_F(NR) = MIN(DZ_F(NR),-ZZ_MIXED_IN(NS)/RN%NU_MW_O_MW_F(NS))
            ENDIF
         ENDDO
      ENDIF
      IF (MASS_OX_STOICH > MASS_OX .AND. RN%HEAT_OF_COMBUSTION > 0._EB) THEN
         DZ_F_SUM = DZ_F_SUM + DZ_F(NR)
      ENDIF
   ENDDO
   DO NR = 1,N_REACTIONS
      RN => REACTION(NR) 
      IF (MASS_OX_STOICH > MASS_OX .AND. RN%HEAT_OF_COMBUSTION > 0._EB) THEN 
         DZ_FRAC_F(NR) = DZ_F(NR)/MAX(DZ_F_SUM,TWO_EPSILON_EB)
         IF (.NOT. RN%FAST_CHEMISTRY) THEN
            RATE_CONSTANT(NR) = DZ_FR(NR)
         ELSE
            IF (.NOT. EXTINCT(NR)) THEN
               RATE_CONSTANT(NR) = DZ_F(NR)*DZ_FRAC_F(NR)/DT_SUB
            ELSE
               RATE_CONSTANT(NR) = 0._EB
            ENDIF 
         ENDIF
      ELSE
         IF (.NOT. RN%FAST_CHEMISTRY) THEN
            RATE_CONSTANT(NR) = DZ_FR(NR)
         ELSE
            IF (.NOT. EXTINCT(NR)) THEN
               RATE_CONSTANT(NR) = DZ_F(NR)/DT_SUB
            ELSE
               RATE_CONSTANT(NR) = 0._EB
            ENDIF
         ENDIF
      ENDIF
   ENDDO
ENDIF
RETURN

END SUBROUTINE COMPUTE_RATE_CONSTANT


SUBROUTINE EXTINCTION(ZZ_MIXED_IN,TMP_MIXED_ZONE,EXTINCT)
REAL(EB), INTENT(IN) :: ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED_ZONE
LOGICAL, INTENT(INOUT) :: EXTINCT(1:N_REACTIONS)
INTEGER :: NR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

SELECT CASE (EXTINCT_MOD)
   CASE(EXTINCTION_1)
      EXTINCT(:) = .FALSE.
      DO NR = 1,N_REACTIONS
         RN => REACTION(NR)
         IF (RN%FAST_CHEMISTRY) THEN
            IF(EXTINCT_1(ZZ_MIXED_IN,TMP_MIXED_ZONE,NR)) EXTINCT(NR) = .TRUE.
         ENDIF
      ENDDO
   CASE(EXTINCTION_2)
      EXTINCT(:) = .FALSE.
      DO NR = 1,N_REACTIONS
         RN => REACTION(NR)
         IF (RN%FAST_CHEMISTRY) THEN
            IF(EXTINCT_2(ZZ_MIXED_IN,TMP_MIXED_ZONE,NR)) EXTINCT(NR) = .TRUE.
         ENDIF
      ENDDO
   CASE(EXTINCTION_3)
      EXTINCT(:) = .FALSE.
      IF (ANY(REACTION(:)%FAST_CHEMISTRY)) THEN
         IF(EXTINCT_3(ZZ_MIXED_IN,TMP_MIXED_ZONE)) THEN
            DO NR = 1,N_REACTIONS
               RN => REACTION(NR)
               IF (RN%FAST_CHEMISTRY) EXTINCT(NR) = .TRUE.
            ENDDO
         ENDIF
      ENDIF   
END SELECT

END SUBROUTINE EXTINCTION


LOGICAL FUNCTION EXTINCT_1(ZZ_IN,TMP_MIXED_ZONE,NR)
USE PHYSICAL_FUNCTIONS,ONLY:GET_AVERAGE_SPECIFIC_HEAT
REAL(EB),INTENT(IN)::ZZ_IN(0:N_TRACKED_SPECIES),TMP_MIXED_ZONE
REAL(EB):: Y_O2,Y_O2_CRIT,CPBAR
INTEGER, INTENT(IN) :: NR
INTEGER :: NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()
RN => REACTION(NR)

EXTINCT_1 = .FALSE.
IF (TMP_MIXED_ZONE < RN%AUTO_IGNITION_TEMPERATURE) THEN
   EXTINCT_1 = .TRUE.
ELSE
   CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_IN,CPBAR,TMP_MIXED_ZONE)
   DO NS = 0,N_TRACKED_SPECIES
      IF (RN%NU(NS)<-TWO_EPSILON_EB .AND. NS/=RN%FUEL_SMIX_INDEX) THEN
         Y_O2 = ZZ_IN(NS)
      ENDIF
   ENDDO
   Y_O2_CRIT = CPBAR*(RN%CRIT_FLAME_TMP-TMP_MIXED_ZONE)/RN%EPUMO2
   IF (Y_O2 < Y_O2_CRIT) EXTINCT_1 = .TRUE.
ENDIF

END FUNCTION EXTINCT_1

LOGICAL FUNCTION EXTINCT_2(ZZ_MIXED_IN,TMP_MIXED_ZONE,NR)
USE PHYSICAL_FUNCTIONS,ONLY:GET_SENSIBLE_ENTHALPY
REAL(EB),INTENT(IN)::ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED_ZONE
REAL(EB):: Z_F,ZZ_HAT_F,ZZ_GET_F(0:N_TRACKED_SPECIES),Z_A,ZZ_HAT_A,ZZ_GET_A(0:N_TRACKED_SPECIES),Z_P,ZZ_HAT_P,&
           ZZ_GET_P(0:N_TRACKED_SPECIES),ZZ_GET_PFP(0:N_TRACKED_SPECIES),H_F_0,H_A_0,H_P_0,H_P_N
INTEGER, INTENT(IN) :: NR
INTEGER :: NS
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()
RN => REACTION(NR)

EXTINCT_2 = .FALSE.
IF (TMP_MIXED_ZONE < RN%AUTO_IGNITION_TEMPERATURE) THEN
   EXTINCT_2 = .TRUE.
ELSE
   ZZ_GET_F = 0._EB
   ZZ_GET_A = 0._EB
   ZZ_GET_P = ZZ_MIXED_IN
   ZZ_GET_PFP = ZZ_MIXED_IN

   Z_F = ZZ_MIXED_IN(RN%FUEL_SMIX_INDEX)
   ZZ_GET_P(RN%FUEL_SMIX_INDEX) = MAX(ZZ_GET_P(RN%FUEL_SMIX_INDEX)-Z_F,0._EB)
   DO NS = 0,N_TRACKED_SPECIES      
      IF (RN%NU(NS) < 0._EB .AND. NS /= RN%FUEL_SMIX_INDEX) THEN
         ZZ_HAT_F = MIN(Z_F,ZZ_MIXED_IN(NS)/RN%S) ! FDS Tech Guide (5.16)
         ZZ_GET_F(RN%FUEL_SMIX_INDEX) = ZZ_HAT_F
         ZZ_GET_PFP(RN%FUEL_SMIX_INDEX) = MAX(ZZ_GET_PFP(RN%FUEL_SMIX_INDEX)-ZZ_HAT_F,0._EB)
         Z_A = ZZ_MIXED_IN(NS)
         ZZ_HAT_A = ZZ_HAT_F*RN%S ! FDS Tech Guide (5.17)
         ZZ_GET_A(NS) = ZZ_HAT_A
         ZZ_GET_P(NS) = MAX(ZZ_GET_P(NS)-ZZ_MIXED_IN(NS),0._EB)
         ZZ_GET_PFP(NS) = MAX(ZZ_GET_PFP(NS)-ZZ_MIXED_IN(NS),0._EB)
      ENDIF
   ENDDO
   Z_P = 1._EB - Z_F - Z_A
   ZZ_HAT_P = (ZZ_HAT_A/(Z_A+TWO_EPSILON_EB))*(Z_F - ZZ_HAT_F + Z_P) ! FDS Tech Guide (5.18)
   DO NS = 0,N_TRACKED_SPECIES
      IF (RN%NU(NS) >= 0._EB) THEN
         ZZ_GET_PFP(NS) = ZZ_GET_P(NS) + ZZ_GET_F(RN%FUEL_SMIX_INDEX)*RN%NU_MW_O_MW_F(NS)
      ENDIF
   ENDDO
   
   !Normalize concentrations
   ZZ_GET_F = ZZ_GET_F/(SUM(ZZ_GET_F)+TWO_EPSILON_EB)
   ZZ_GET_A = ZZ_GET_A/(SUM(ZZ_GET_A)+TWO_EPSILON_EB)
   ZZ_GET_P = ZZ_GET_P/(SUM(ZZ_GET_P)+TWO_EPSILON_EB)
   ZZ_GET_PFP = ZZ_GET_PFP/(SUM(ZZ_GET_PFP)+TWO_EPSILON_EB)

   ! Get the specific heat for the fuel and diluent at the current and critical flame temperatures
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_F,H_F_0,TMP_MIXED_ZONE)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_A,H_A_0,TMP_MIXED_ZONE)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_P,H_P_0,TMP_MIXED_ZONE)  
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_PFP,H_P_N,RN%CRIT_FLAME_TMP)
   
   ! See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp. 
   IF (ZZ_HAT_F*(H_F_0+RN%HEAT_OF_COMBUSTION) + ZZ_HAT_A*H_A_0 + ZZ_HAT_P*H_P_0 < &
      (ZZ_HAT_F+ZZ_HAT_A+ZZ_HAT_P)*H_P_N) EXTINCT_2 = .TRUE. ! FDS Tech Guide (5.19)
ENDIF

END FUNCTION EXTINCT_2

LOGICAL FUNCTION EXTINCT_3(ZZ_MIXED_IN,TMP_MIXED_ZONE)
USE PHYSICAL_FUNCTIONS,ONLY:GET_SENSIBLE_ENTHALPY
REAL(EB),INTENT(IN)::ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED_ZONE
REAL(EB):: H_F_0,H_A_0,H_P_0,H_P_N,Z_F,Z_A,Z_P,Z_A_STOICH,ZZ_HAT_F,ZZ_HAT_A,ZZ_HAT_P,&
           ZZ_GET_F(0:N_TRACKED_SPECIES),ZZ_GET_A(0:N_TRACKED_SPECIES),ZZ_GET_P(0:N_TRACKED_SPECIES),ZZ_GET_F_REAC(1:N_REACTIONS),&
           ZZ_GET_PFP(0:N_TRACKED_SPECIES),DZ_F(1:N_REACTIONS),DZ_FRAC_F(1:N_REACTIONS),DZ_F_SUM,&
           HOC_EXTINCT,AIT_EXTINCT,CFT_EXTINCT
INTEGER :: NS,NR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

EXTINCT_3 = .FALSE.
Z_F = 0._EB
Z_A = 0._EB
Z_P = 0._EB
DZ_F = 0._EB
DZ_F_SUM = 0._EB
Z_A_STOICH = 0._EB
ZZ_GET_F = 0._EB
ZZ_GET_A = 0._EB
ZZ_GET_P = ZZ_MIXED_IN
ZZ_GET_PFP = 0._EB
HOC_EXTINCT = 0._EB
AIT_EXTINCT = 0._EB
CFT_EXTINCT = 0._EB

DO NS=0,N_TRACKED_SPECIES
   SUM_FUEL_LOOP: DO NR = 1,N_REACTIONS
      RN => REACTION(NR)
      IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB .AND. NS == RN%FUEL_SMIX_INDEX) THEN
         Z_F = Z_F + ZZ_MIXED_IN(NS)
         EXIT SUM_FUEL_LOOP
      ENDIF
   ENDDO SUM_FUEL_LOOP
   SUM_AIR_LOOP: DO NR = 1,N_REACTIONS
      RN => REACTION(NR)
      IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB .AND. RN%NU(NS) < 0._EB .AND. NS /= RN%FUEL_SMIX_INDEX) THEN
         Z_A = Z_A + ZZ_MIXED_IN(NS)
         ZZ_GET_P(NS) = MAX(ZZ_GET_P(NS) - ZZ_MIXED_IN(NS),0._EB)
         EXIT SUM_AIR_LOOP
      ENDIF
   ENDDO SUM_AIR_LOOP
ENDDO
Z_P = 1._EB - Z_F - Z_A
DO NR = 1,N_REACTIONS
   RN => REACTION(NR)
   IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB) THEN
      DZ_F(NR) = 1.E10_EB
      DO NS = 0,N_TRACKED_SPECIES
         IF (RN%NU(NS) < 0._EB) THEN
            DZ_F(NR) = MIN(DZ_F(NR),-ZZ_MIXED_IN(NS)/RN%NU_MW_O_MW_F(NS))
         ENDIF
         IF (RN%NU(NS) < 0._EB .AND. NS /= RN%FUEL_SMIX_INDEX) THEN
            Z_A_STOICH = Z_A_STOICH + ZZ_MIXED_IN(RN%FUEL_SMIX_INDEX)*RN%S
         ENDIF
      ENDDO
   ENDIF
ENDDO
IF (Z_A_STOICH > Z_A) DZ_F_SUM = SUM(DZ_F)
DO NR = 1,N_REACTIONS
   RN => REACTION(NR) 
   IF (Z_A_STOICH > Z_A .AND. RN%HEAT_OF_COMBUSTION > 0._EB) THEN 
      DZ_FRAC_F(NR) = DZ_F(NR)/MAX(DZ_F_SUM,TWO_EPSILON_EB)
      ZZ_GET_F(RN%FUEL_SMIX_INDEX) = DZ_F(NR)*DZ_FRAC_F(NR)
      ZZ_GET_P(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX) - ZZ_GET_F(RN%FUEL_SMIX_INDEX)
      ZZ_GET_PFP(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX)
      DO NS = 0,N_TRACKED_SPECIES
         IF (RN%NU(NS)< 0._EB .AND. NS/=RN%FUEL_SMIX_INDEX) THEN
            ZZ_GET_A(NS) = RN%S*ZZ_GET_F(RN%FUEL_SMIX_INDEX)
!            ZZ_GET_P(NS) = ZZ_GET_P(NS) - ZZ_GET_A(NS)
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS)
         ELSEIF (RN%NU(NS) >= 0._EB ) THEN
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS) + ZZ_GET_F(RN%FUEL_SMIX_INDEX)*RN%NU_MW_O_MW_F(NS)
         ENDIF
      ENDDO
   ELSE
      ZZ_GET_F(RN%FUEL_SMIX_INDEX) = DZ_F(NR)
      ZZ_GET_P(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX) - ZZ_GET_F(RN%FUEL_SMIX_INDEX)
      ZZ_GET_PFP(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX)
      DO NS = 0,N_TRACKED_SPECIES
         IF (RN%NU(NS) < 0._EB .AND. NS/=RN%FUEL_SMIX_INDEX) THEN
            ZZ_GET_A(NS) = RN%S*ZZ_GET_F(RN%FUEL_SMIX_INDEX)
!            ZZ_GET_P(NS) = ZZ_GET_P(NS) - ZZ_GET_A(NS)
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS)
         ELSEIF (RN%NU(NS) >= 0._EB ) THEN
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS) + ZZ_GET_F(RN%FUEL_SMIX_INDEX)*RN%NU_MW_O_MW_F(NS)
         ENDIF
      ENDDO
   ENDIF
   ZZ_GET_F_REAC(NR) = ZZ_GET_F(RN%FUEL_SMIX_INDEX)
ENDDO

ZZ_HAT_F = SUM(ZZ_GET_F)
ZZ_HAT_A = SUM(ZZ_GET_A)
ZZ_HAT_P = (ZZ_HAT_A/(Z_A+TWO_EPSILON_EB))*(Z_F-ZZ_HAT_F+SUM(ZZ_GET_P))
!M_P_ST = SUM(ZZ_GET_P)

! Normalize compositions
ZZ_GET_F = ZZ_GET_F/(SUM(ZZ_GET_F)+TWO_EPSILON_EB)
ZZ_GET_F_REAC = ZZ_GET_F_REAC/(SUM(ZZ_GET_F_REAC)+TWO_EPSILON_EB)
ZZ_GET_A = ZZ_GET_A/(SUM(ZZ_GET_A)+TWO_EPSILON_EB)
ZZ_GET_P = ZZ_GET_P/(SUM(ZZ_GET_P)+TWO_EPSILON_EB)
ZZ_GET_PFP = ZZ_GET_PFP/(SUM(ZZ_GET_PFP)+TWO_EPSILON_EB)

DO NR = 1,N_REACTIONS
   RN => REACTION(NR)
   AIT_EXTINCT = AIT_EXTINCT+ZZ_GET_F_REAC(NR)*RN%AUTO_IGNITION_TEMPERATURE
   CFT_EXTINCT = CFT_EXTINCT+ZZ_GET_F_REAC(NR)*RN%CRIT_FLAME_TMP
   HOC_EXTINCT = HOC_EXTINCT+ZZ_GET_F_REAC(NR)*RN%HEAT_OF_COMBUSTION
ENDDO
   
IF (TMP_MIXED_ZONE < AIT_EXTINCT) THEN
   EXTINCT_3 = .TRUE.
ELSE     
   ! Get the specific heat for the fuel and diluent at the current and critical flame temperatures
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_F,H_F_0,TMP_MIXED_ZONE)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_A,H_A_0,TMP_MIXED_ZONE)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_P,H_P_0,TMP_MIXED_ZONE)  
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_PFP,H_P_N,CFT_EXTINCT)
   
   ! See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp. 
   IF (ZZ_HAT_F*(H_F_0+HOC_EXTINCT) + ZZ_HAT_A*H_A_0 + ZZ_HAT_P*H_P_0 < &
      (ZZ_HAT_F+ZZ_HAT_A+ZZ_HAT_P)*H_P_N) EXTINCT_3 = .TRUE. ! FED Tech Guide (5.19)
ENDIF

END FUNCTION EXTINCT_3


SUBROUTINE GET_REV_fire(MODULE_REV,MODULE_DATE)
INTEGER,INTENT(INOUT) :: MODULE_REV
CHARACTER(255),INTENT(INOUT) :: MODULE_DATE

WRITE(MODULE_DATE,'(A)') firerev(INDEX(firerev,':')+2:LEN_TRIM(firerev)-2)
READ (MODULE_DATE,'(I5)') MODULE_REV
WRITE(MODULE_DATE,'(A)') firedate

END SUBROUTINE GET_REV_fire

 
END MODULE FIRE

