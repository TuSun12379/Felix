!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
! Felix
!
! Richard Beanland, Keith Evans & Rudolf A Roemer
!
! (C) 2013-17, all rights reserved
!
! Version: :VERSION:
! Date:    :DATE:
! Time:    :TIME:
! Status:  :RLSTATUS:
! Build:   :BUILD:
! Author:  :AUTHOR:
! 
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
!  Felix is free software: you can redistribute it and/or modify
!  it under the terms of the GNU General Public License as published by
!  the Free Software Foundation, either version 3 of the License, or
!  (at your option) any later version.
!  
!  Felix is distributed in the hope that it will be useful,
!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!  GNU General Public License for more details.
!  
!  You should have received a copy of the GNU General Public License
!  along with Felix.  If not, see <http://www.gnu.org/licenses/>.
!
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

! Conatained in this file below:
! BlochCoefficientCalculation()
! CreateWaveFunctions()
! StrongAndWeakBeamsDetermination()
! EigenSpectrum()
! INVERT()


!>
!! Module-description: Holds BlochCoefficientCalculation which for a pixel
!! calculates the wavefunction vector for each thickness
!!
MODULE bloch_mod
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: BlochCoefficientCalculation

  CONTAINS

  !>
  !! Procedure-description: Simulates the electron beam and calculates Bloch
  !! coefficients, conisdering complex amplitudes and iterating over the thickness
  !!
  !! Major-Authors: Keith Evans (2014), Richard Beanland (2016)
  !!
  SUBROUTINE BlochCoefficientCalculation(IYPixelIndex,IXPixelIndex,IPixelNumber,&
                    IFirstPixelToCalculate,IErr)

    USE MyNumbers
    USE IConst, ONLY : ITHREE
    USE MyMPI
    USE message_mod
    USE l_alert_mod 
   
    ! globals - input  
    USE CPara, ONLY : CUgMat ! from Absorption
    USE RPara, ONLY : &
      RDeltaK,& ! resolution in k space, used in calculations
      RDeltaThickness,& ! input from felix.inp
      RInitialThickness,& ! input from felix.inp
      RNormDirM,RgDotNorm,RgPool,RgPoolMag,&
      Rhkl ! from HKLMake ..fill reflection pool
    USE IPara, ONLY : &
      IHKLSelectFLAG,&
      IHolzFLAG,& ! higher order Laue
      IImageFLAG,&
      IMinStrongBeams,IMinWeakBeams,&
      INoOfLacbedPatterns,&
      IPixelCount,&
      IThicknessCount,&
      nReflections,&
      IOutputReflections
    USE BlochPara, ONLY : RBigK ! from StructureFactorInitialisation            
    
    ! globals - output
    USE RPara, ONLY : RIndividualReflections 
    USE CPara, ONLY : CAmplitudeandPhase
    ! /\ matrix of vectors, thickness, pixel, wavefunction this contributes
    ! one pixel and some parallelises in fexlixfunction join later
    USE IPara, ONLY : IPixelComputed
    
    IMPLICIT NONE
    
    INTEGER(IKIND),INTENT(IN) :: IYPixelIndex,IXPixelIndex,IPixelNumber,&
          IFirstPixelToCalculate
    INTEGER(IKIND),INTENT(OUT) :: IErr
    
    ! local - previously global !?? track allocations & global remnants
    COMPLEX(CKIND),ALLOCATABLE :: CBeamProjectionMatrix(:,:),&
          CDummyBeamMatrix(:,:),CUgSgMatrix(:,:),CEigenVectors(:,:),CEigenValues(:),&
          CInvertedEigenVectors(:,:),CAlphaWeightingCoefficients(:),&
          CEigenValueDependentTerms(:,:)
    COMPLEX(CKIND) :: CFullWaveFunctions(nReflections)
    REAL(RKIND) :: RFullWaveIntensity(nReflections),RDevPara(nReflections),&
          RTiltedK(ITHREE)
    INTEGER(IKIND) :: IStrongBeamList(nReflections),IWeakBeamList(nReflections),&
          nBeams,nWeakBeams

    ! local - previously local
    INTEGER(IKIND) :: ind,knd,pnd,IThickness,IThicknessIndex,ILowerLimit,&
          IUpperLimit       
    REAL(RKIND) :: RThickness,RKn
    COMPLEX(CKIND) sumC,sumD
    COMPLEX(CKIND), DIMENSION(:,:), ALLOCATABLE :: CGeneralSolutionMatrix, &
         CGeneralEigenSpectrumEigenVectors,CBeamTranspose,CUgMatPartial
    COMPLEX(CKIND),DIMENSION(:),ALLOCATABLE :: CGeneralEigenValues
    CHARACTER*40 surname
    CHARACTER*200 SindString,SjndString,SPixelCount,SnBeams,SWeakBeamIndex,SPrintString
      
    ! we are inside the mask
    IPixelComputed= IPixelComputed + 1

    ! TiltedK is the vector of the incoming tilted beam
    ! in units of (1/A), in the microscope ref frame(NB exp(i*k.r), physics convention)
    ! x-position in k-space
    RTiltedK(1)= (REAL(IYPixelIndex,RKIND)-REAL(IPixelCount,RKIND)-0.5_RKIND)*RDeltaK
    ! y-position in k-space
    RTiltedK(2)= (REAL(IXPixelIndex,RKIND)-REAL(IPixelCount,RKIND)-0.5_RKIND)*RDeltaK 
    RTiltedK(3)= SQRT(RBigK**2 - RTiltedK(1)**2 - RTiltedK(2)**2) 
    RKn = DOT_PRODUCT(RTiltedK,RNormDirM)
    
    ! Compute the deviation parameter for reflection pool
    ! NB RDevPara is in units of (1/A), in the microscope ref frame(NB exp(i*s.r), physics convention)
    DO knd=1,nReflections
      ! Sg parallel to z: Sg=-[k'z+gz-sqrt( (k'z+gz)^2-2k'.g-g^2)]
      RDevPara(knd)= -RTiltedK(3)-RgPool(knd,3)+&
	    SQRT( (RTiltedK(3)+RgPool(knd,3))**2-2*DOT_PRODUCT(RgPool(knd,:),RTiltedK(:))-RgPoolMag(knd)**2)

      !??  remove below commented out
      !Keith's old version, Sg parallel to k'
      !RDevPara(knd)= -( RBigK + DOT_PRODUCT(RgPool(knd,:),RTiltedK(:)) /RBigK) + &
      !  SQRT( ( RBigK**2 + DOT_PRODUCT(RgPool(knd,:),RTiltedK(:)) )**2 /RBigK**2 - &
      !  (RgPoolMag(knd)**2 + TWO*DOT_PRODUCT(RgPool(knd,:),RTiltedK(:))) )
      IF(knd.EQ.2.AND.IYPixelIndex.EQ.10.AND.IXPixelIndex.EQ.10) THEN
        CALL message(LL,dbg7,"RBigK ",RBigK)
        CALL message(LL,dbg7,"Rhkl(knd) ",Rhkl(knd:knd,:))
        CALL message(LL,dbg7,"RgPool(knd) ",RgPool(knd:knd,:))
        CALL message(LL,dbg7,"RTiltedK ",RTiltedK)
        CALL message(LL,dbg7,"RDevPara ",RDevPara(knd))
      END IF
    END DO

    ! select only those beams where the Ewald sphere is close to the
    ! reciprocal lattice, i.e. within RBSMaxDeviationPara
    CALL StrongAndWeakBeamsDetermination(nReflections,IMinWeakBeams,&
                    IMinStrongBeams,RDevPara,CUgMat,&
                    IStrongBeamList,IWeakBeamList,nBeams,nWeakBeams,IErr)
    IF( IErr.NE.0 ) THEN
      PRINT*,"Error:BlochCoefficientCalculation(",my_rank,&
            ") error in Determination of Strong and Weak beams"
      RETURN
    END IF
    CALL message(LL,dbg7,"strong beams",nBeams)
    CALL message(LL,dbg7,"weak beams",nWeakBeams)
    CALL message(LL,dbg7,"nReflections",nReflections)

    !--------------------------------------------------------------------
    ! ALLOCATE memory for eigen problem
    !--------------------------------------------------------------------

    ! now nBeams determined, allocate complex arrays
    ALLOCATE(CBeamProjectionMatrix(nBeams,nReflections),STAT=IErr)
    ALLOCATE(CDummyBeamMatrix(nBeams,nReflections),STAT=IErr)
    ALLOCATE(CUgSgMatrix(nBeams,nBeams),STAT=IErr)
    ALLOCATE(CEigenVectors(nBeams,nBeams),STAT=IErr)
    ALLOCATE(CEigenValues(nBeams),STAT=IErr)
    ALLOCATE(CInvertedEigenVectors(nBeams,nBeams),STAT=IErr)
    ALLOCATE(CBeamTranspose(nReflections,nBeams),STAT=IErr)
    ALLOCATE(CUgMatPartial(nReflections,nBeams),STAT=IErr)
    ALLOCATE(CAlphaWeightingCoefficients(nBeams),STAT=IErr)
    ALLOCATE(CEigenValueDependentTerms(nBeams,nBeams),STAT=IErr)
    IF( IErr.NE.0 ) THEN
      PRINT*,"Error:BlochCoefficientCalculation(",my_rank,")error in allocations"
      RETURN
    END IF
    
    ! compute the effective Ug matrix by selecting only those beams
    ! for which IStrongBeamList has an entry
    CBeamProjectionMatrix= CZERO
    DO knd=1,nBeams
      CBeamProjectionMatrix(knd,IStrongBeamList(knd))=CONE
    ENDDO

    CUgSgMatrix = CZERO
    CBeamTranspose=TRANSPOSE(CBeamProjectionMatrix)
    ! reduce the matrix to just include strong beams using some nifty matrix multiplication
    CALL ZGEMM('N','N',nReflections,nBeams,nReflections,CONE,CUgMat, &
              nReflections,CBeamTranspose,nReflections,CZERO,CUgMatPartial,nReflections)
    CALL ZGEMM('N','N',nBeams,nBeams,nReflections,CONE,CBeamProjectionMatrix, &
              nBeams,CUgMatPartial,nReflections,CZERO,CUgSgMatrix,nBeams)

    !--------------------------------------------------------------------
    ! consider Laue zones, possibly higher order
    !--------------------------------------------------------------------

    IF (IHolzFLAG.EQ.1) THEN
      DO ind=1,nBeams
        CUgSgMatrix(ind,ind) = CUgSgMatrix(ind,ind) + TWO*RBigK*RDevPara(IStrongBeamList(ind))
      ENDDO
      DO knd =1,nBeams ! Columns
        DO ind = 1,nBeams ! Rows
          CUgSgMatrix(knd,ind) = CUgSgMatrix(knd,ind) / &
                (SQRT(1+RgDotNorm(IStrongBeamList(knd))/RKn)*&
                SQRT(1+RgDotNorm(IStrongBeamList(ind))/RKn))
        END DO
      END DO
      CUgSgMatrix = (TWOPI**2)*CUgSgMatrix/(TWO*RBigK)
    ELSE
      ! replace the diagonal parts with strong beam deviation parameters
      DO ind=1,nBeams
        CUgSgMatrix(ind,ind) = TWO*RBigK*RDevPara(IStrongBeamList(ind))/(TWOPI*TWOPI)
      ENDDO
      ! add the weak beams perturbatively for the 1st column (sumC) and
      ! the diagonal elements (sumD)
      DO knd=2,nBeams
        sumC=CZERO
        sumD=CZERO
        DO ind=1,nWeakBeams
		      ! Zuo&Weickenmeier Ultramicroscopy 57 (1995) 375-383 eq.4
          sumC=sumC + &
          CUgMat(IStrongBeamList(knd),IWeakBeamList(ind))*&
          CUgMat(IWeakBeamList(ind),1)/(TWO*RBigK*RDevPara(IWeakBeamList(ind)))

          !??  remove commented Keith's old version
          !REAL(CUgMat(IStrongBeamList(knd),IWeakBeamList(ind))) * &
          !REAL(CUgMat(IWeakBeamList(ind),1)) / &
          !(4*RBigK*RBigK*RDevPara(IWeakBeamList(ind)))
          sumD = sumD + &
		      ! Zuo&Weickenmeier Ultramicroscopy 57 (1995) 375-383 eq.5
          CUgMat(IStrongBeamList(knd),IWeakBeamList(ind))*&
          CUgMat(IWeakBeamList(ind),IStrongBeamList(knd))/&
          (TWO*RBigK*RDevPara(IWeakBeamList(ind)))
          !?? remove commented Keith's old version
          !REAL(CUgMat(IStrongBeamList(knd),IWeakBeamList(ind))) * &
          !REAL(CUgMat(IWeakBeamList(ind),IStrongBeamList(knd))) / &
          !(4*RBigK*RBigK*RDevPara(IWeakBeamList(ind)))
        ENDDO
	      ! Replace the Ug's
	      WHERE (CUgSgMatrix.EQ.CUgSgMatrix(knd,1))
          CUgSgMatrix= CUgSgMatrix(knd,1) - sumC
	      END WHERE
	      ! Replace the Sg's
        CUgSgMatrix(knd,knd)= CUgSgMatrix(knd,knd) - TWO*RBigK*sumD/(TWOPI*TWOPI)
      ENDDO
      ! Divide by 2K so off-diagonal elementa are Ug/2K, diagonal elements are Sg
      !?? DON'T KNOW WHERE THE 4pi^2 COMES FROM 
      CUgSgMatrix = TWOPI*TWOPI*CUgSgMatrix/(TWO*RBigK)
    END IF

    IF(IYPixelIndex.EQ.10.AND.IXPixelIndex.EQ.10) THEN ! output data from 1 pixel to show working
      CALL message(LL,dbg3, "Pixel [10,10] Ug/2K + {Sg} matrix (nm^-2)")
      CALL message(LL,dbg3, "displaying Rhkl and 100*CUgSgMatrix alongside",&
            NINT(Rhkl(1:16,:)),100*CUgSgMatrix(1:16,1:6))
    END IF
    
    !--------------------------------------------------------------------
    ! diagonalize the UgMatEffective
    !--------------------------------------------------------------------

    IF (IHolzFLAG.EQ.1) THEN ! limit simulation to zeroth order Laue zone
      CALL EigenSpectrum(nBeams,CUgSgMatrix,CEigenValues(:), CEigenVectors(:,:),IErr)
      IF( IErr.NE.0 ) THEN
        PRINT*,"Error:BlochCoefficientCalculation(", my_rank, ") error in EigenSpectrum()"
        RETURN
      END IF
      CEigenValues = CEigenValues * RKn/RBigK    !?? What is this doing?
      DO knd = 1,nBeams
        CEigenVectors(knd,:) = CEigenVectors(knd,:) / &
              SQRT(1+RgDotNorm(IStrongBeamList(knd))/RKn)
      END DO
    ELSE ! Use Laue zones beyond zeroth order !?? does this work?
      CALL EigenSpectrum(nBeams,CUgSgMatrix,CEigenValues(:),CEigenVectors(:,:),IErr)
    END IF

    IF( IErr.NE.0 ) THEN
      PRINT*,"Error:BlochCoefficientCalculation(",my_rank,") error in EigenSpectrum()"
      RETURN
    END IF
   
    ! Calculate intensities for different specimen thicknesses
    !?? ADD VARIABLE PATH LENGTH HERE
    DO IThicknessIndex=1,IThicknessCount,1
      RThickness = RInitialThickness + REAL((IThicknessIndex-1),RKIND)*RDeltaThickness 
      IThickness = NINT(RThickness,IKIND)
      CALL CreateWaveFunctions(RThickness,RFullWaveIntensity,CFullWaveFunctions,&
                    nReflections,nBeams,IStrongBeamList,CEigenVectors,CEigenValues,IErr)
      IF(l_alert(IErr,"BlochCoefficientCalculation","CreateWaveFunctions")) RETURN
      ! Collect Intensities from all thickness for later writing
      IF(IHKLSelectFLAG.EQ.0) THEN ! we are using hkl list from felix.hkl
        IF(IImageFLAG.LE.2) THEN ! output is 0=montage, 1=individual images
          RIndividualReflections(1:INoOfLacbedPatterns,IThicknessIndex,&
                (IPixelNumber-IFirstPixelToCalculate)+1) = &
                RFullWaveIntensity(1:INoOfLacbedPatterns)
        ELSE ! output is 2=amplitude+phase images
          CAmplitudeandPhase(1:INoOfLacbedPatterns,IThicknessIndex,&
                (IPixelNumber-IFirstPixelToCalculate)+1) = &
                CFullWavefunctions(1:INoOfLacbedPatterns)
        END IF
      ELSE ! we are using hkl list from [where?]
        IF(IImageFLAG.LE.2) THEN
          DO pnd = 1,INoOfLacbedPatterns
            RIndividualReflections(pnd,IThicknessIndex,&
                  (IPixelNumber-IFirstPixelToCalculate)+1) = &
                  RFullWaveIntensity(IOutputReflections(pnd))
          END DO
        ELSE
          DO pnd = 1,INoOfLacbedPatterns
            CAmplitudeandPhase(pnd,IThicknessIndex,(IPixelNumber-IFirstPixelToCalculate)+1) = &
                 CFullWavefunctions(IOutputReflections(pnd))
          END DO
        END IF
      END IF
    END DO
    
    ! DEALLOCATE eigen problem memory
    DEALLOCATE(CUgSgMatrix,CBeamTranspose, CUgMatPartial, &
         CInvertedEigenVectors, CAlphaWeightingCoefficients, &
         CEigenValues,CEigenVectors,CEigenValueDependentTerms, &
         CBeamProjectionMatrix, CDummyBeamMatrix,STAT=IErr)
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:BlochCoefficientCalculation(",my_rank,") error in Deallocations"
       RETURN
    END IF
    
  END SUBROUTINE BlochCoefficientCalculation

  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



  !>
  !! Procedure-description: Calculates diffracted intensity for a specific thickness
  !!
  !! Closed procedure, no access to global variables
  !!
  !! Major-Authors: Keith Evans (2014), Richard Beanland (2016)
  !!
  SUBROUTINE CreateWaveFunctions(RThickness,RFullWaveIntensity0,CFullWaveFunctions0,&
                    nReflections0,nBeams0,IStrongBeamList0,CEigenVectors0,CEigenValues0,IErr)
    !?? all global varibles on in/out are local to bloch excluding nReflections

    !?? only called inside bloch.f90
    USE MyNumbers
    USE MyMPI
    USE message_mod 
    USE l_alert_mod

    IMPLICIT NONE
    
    REAL(RKIND) :: RThickness ! non-global input
    ! global inputs and outputs
    REAL(RKIND),DIMENSION(nReflections0),INTENT(OUT) :: RFullWaveIntensity0
    COMPLEX(CKIND),DIMENSION(nReflections0),INTENT(OUT) :: CFullWaveFunctions0  
    INTEGER(IKIND),INTENT(IN) :: nReflections0,nBeams0,IStrongBeamList0(nReflections0)
    COMPLEX(CKIND),INTENT(IN) :: CEigenVectors0(nBeams0,nBeams0),CEigenValues0(nBeams0)
    INTEGER(IKIND),INTENT(OUT) :: IErr ! non-global, classic IErr  
    !?? old globals, now used locally
    REAL(RKIND) :: RWaveIntensity(nBeams0)
    COMPLEX(CKIND) :: CInvertedEigenVectors(nBeams0,nBeams0),CPsi0(nBeams0),&
          CWaveFunctions(nBeams0),CEigenValueDependentTerms(nBeams0,nBeams0),&
          CAlphaWeightingCoefficients(nBeams0)
    ! locals
    INTEGER(IKIND) :: ind,jnd,knd,hnd,ifullind,iuniind,gnd,ichnk
    COMPLEX(CKIND),DIMENSION(:,:),ALLOCATABLE :: CDummyEigenVectors

    ! Allocate global variables for eigen problem
    !?? ALLOCATE(RWaveIntensity(nBeams0),STAT=IErr)  
    !?? ALLOCATE(CWaveFunctions(nBeams0),STAT=IErr)
    ALLOCATE(CDummyEigenVectors(nBeams0,nBeams0),STAT=IErr)
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:CreateWavefunctions(",my_rank,")error in allocations"
       RETURN
    END IF
    
    ! The top surface boundary conditions
    !?? ALLOCATE(CPsi0(nBeams0),STAT=IErr) 
    CPsi0 = CZERO ! all diffracted beams are zero
    CPsi0(1) = CONE ! the 000 beam has unit amplitude
    
    ! Invert the EigenVector matrix
    CDummyEigenVectors = CEigenVectors0
    CALL INVERT(nBeams0,CDummyEigenVectors(:,:),CInvertedEigenVectors,IErr)

    ! put in the thickness
    ! From EQ 6.32 in Kirkland Advance Computing in EM
    CAlphaWeightingCoefficients = MATMUL(CInvertedEigenVectors(1:nBeams0,1:nBeams0),CPsi0) 
    CEigenValueDependentTerms= CZERO
    DO hnd=1,nBeams0     ! This is a diagonal matrix
      CEigenValueDependentTerms(hnd,hnd)=EXP(CIMAGONE*CMPLX(RThickness,ZERO,CKIND)*CEigenValues0(hnd)) 
    ENDDO
    ! The diffracted intensity for each beam
    ! EQ 6.35 in Kirkland Advance Computing in EM
    ! C-1*C*alpha 
    CWaveFunctions(:)=MATMUL(MATMUL(CEigenVectors0(1:nBeams0,1:nBeams0),CEigenValueDependentTerms), & 
         CAlphaWeightingCoefficients(:) )
    !?? possible small time saving here by only calculating the (tens of) output
    !?? reflections rather than all strong beams (hundreds)
    DO hnd=1,nBeams0
       RWaveIntensity(hnd)=CONJG(CWaveFunctions(hnd)) * CWaveFunctions(hnd)
    ENDDO  
    
    !--------------------------------------------------------------------
    ! rePADDing of wave function and intensities with zero's 
    !--------------------------------------------------------------------

    CFullWaveFunctions0=CZERO
    RFullWaveIntensity0=ZERO
    DO knd=1,nBeams0
       CFullWaveFunctions0(IStrongBeamList0(knd))=CWaveFunctions(knd)
       RFullWaveIntensity0(IStrongBeamList0(knd))=RWaveIntensity(knd)
    ENDDO
    
    DEALLOCATE(CDummyEigenVectors,STAT=IErr) !?? necessary?
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:CreateWavefunctions(",my_rank,")error deallocating CDummyEigenVectors"
       RETURN
    END IF
    
  END SUBROUTINE CreateWavefunctions

  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



  !>
  !! Procedure-description: Determines number of weak and strong beams. Uses Sg and
  !! pertubation strengths and iterates over the number of weak and strong until
  !! there are enough.
  !!
  !! Closed procedure, no access to global variables
  !!
  !! Major-Authors: Keith Evans (2014), Richard Beanland (2016)
  !!
  SUBROUTINE StrongAndWeakBeamsDetermination(nReflections0,IMinWeakBeams0,&
                    IMinStrongBeams0,RDevPara0,CUgMat0,&
                    IStrongBeamList0,IWeakBeamList0,nBeams0,nWeakBeams0,IErr)
    
    !?? inputs outside bloch nReflections,IMinWeakBeams,IMinStrongBeams
    !?? outputs outside bloch CUgMat

    !?? only called inside bloch.f90
    USE MyNumbers
    USE MyMPI
    USE message_mod 

    !?? variables match up to globals allocation
    !?? make some of these local
    INTEGER(IKIND),INTENT(IN) :: nReflections0
    REAL(RKIND),DIMENSION(nReflections0),INTENT(IN) :: RDevPara0
    COMPLEX(CKIND),DIMENSION(nReflections0,nReflections0),INTENT(IN) :: CUgMat0
    INTEGER(IKIND),INTENT(IN) :: IMinWeakBeams0, IMinStrongBeams0 !?? move integers together
    INTEGER(IKIND),DIMENSION(nReflections0),INTENT(OUT) :: IStrongBeamList0,IWeakBeamList0
    INTEGER(IKIND),INTENT(OUT) :: nBeams0,nWeakBeams0,IErr

    INTEGER(IKIND) :: ind,jnd
    INTEGER(IKIND),DIMENSION(:) :: IStrong(nReflections0),IWeak(nReflections0)
    REAL(RKIND) :: RMaxSg,RMinPertStrong,RMinPertWeak
    REAL(RKIND),DIMENSION(:) :: RPertStrength0(nReflections0)

    !----------------------------------------------------------------------------
    ! strong beams
    !----------------------------------------------------------------------------

    ! Use Sg and perturbation strength to define strong beams
    ! PerturbationStrength Eq. 8 Zuo Ultramicroscopy 57 (1995) 375, |Ug/2KSg|
    ! Here use |Ug/Sg| since 2K is a constant
    ! NB RPertStrength0 is an array of perturbation strengths for all reflections
    RPertStrength0 = ABS(CUgMat0(:,1)/(RDevPara0))
    ! 000 beam is NaN otherwise, always included by making it a large number
    RPertStrength0(1) = 1000.0

    ! NB IStrong is an array listing the strong beams (1=Strong, 0=Not strong)
    IStrong=0_IKIND
    ! start with a small deviation parameter limit
    RMaxSg = 0.005
    RMinPertStrong=0.0025/RMaxSg ! Gives additional beams based on perturbation strength

    ! main calculation
    ! now increase RMaxSg until we have enough strong beams
    DO WHILE (SUM(IStrong).LT.IMinStrongBeams0)
      WHERE (ABS(RDevPara0).LT.RMaxSg.OR.RPertStrength0.GE.RMinPertStrong)
	    IStrong=1_IKIND
	  END WHERE
      RMaxSg=RMaxSg+0.005
      ! RMinPertStrong=0.0025/RMaxSg
    END DO
    !?? should this be do until loop


    ! give the strong beams a number in IStrongBeamList0
    IStrongBeamList0=0_IKIND
    ind=1_IKIND
    DO jnd=1,nReflections0
      IF (IStrong(jnd).EQ.1) THEN
	      IStrongBeamList0(ind)=jnd
        ind=ind+1
	    END IF
    END DO
    !?? could this be done by better array assignment

    ! this is used to give the dimension of the Bloch wave problem
    nBeams0=ind-1  

    CALL message(LXL,dbg7,"Strong Beam List",IStrongBeamList0)
    CALL message(LXL,dbg7,"Sg limit for strong beams = ",RMaxSg)
    CALL message(LXL,dbg7,"Smallest strong perturbation strength = ",RMinPertStrong)
    IF(SUM(IStrong)+IMinWeakBeams0.GT.nReflections0) IErr = 1
    IF( IErr.NE.0 ) THEN
      PRINT*,"Error:StrongAndWeakBeamDetermination(", my_rank, ") error ", IErr, &
            " Insufficient reflections to accommodate all Strong and Weak Beams"
      RETURN
    END IF
    
    !----------------------------------------------------------------------------
    ! weak beams
    !----------------------------------------------------------------------------

    ! Decrease perturbation strength until we have enough weak beams
    ! NB IWeak is an array listing the weak beams (1=Weak, 0=Not weak)
    IWeak=0_IKIND
    RMinPertWeak=0.9*RMinPertStrong
    DO WHILE (SUM(IWeak).LT.IMinWeakBeams0)
      WHERE (RPertStrength0.GE.RMinPertWeak.AND.IStrong.NE.1_IKIND)
	    IWeak=1
	  END WHERE
      RMinPertWeak=0.9*RMinPertWeak
    END DO
    !?? should this be do until loop

    CALL message(LXL,dbg7,"weak beams",SUM(IWeak))
    CALL message(LXL,dbg7,"Smallest weak perturbation strength = ",RMinPertWeak)

    ! give the weak beams a number in IWeakBeamList0
    IWeakBeamList0=0_IKIND
    ind=1_IKIND
    DO jnd=1,nReflections0
      IF (IWeak(jnd).EQ.1) THEN
	    IWeakBeamList0(ind)=jnd
        ind=ind+1
      END IF
    END DO
    !?? could this be done by better array assignment
    nWeakBeams0=ind-1

    CALL message(LXL,dbg7,"Weak Beam List",IWeakBeamList0)

  END SUBROUTINE StrongAndWeakBeamsDetermination

  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



  !>
  !! Procedure-description: Returns eigenvalues and eigenvectors of matrix.
  !!
  !! Closed procedure, no access to global variables
  !!
  !! Major-Authors: Keith Evans (2014), Richard Beanland (2016)
  !!
  SUBROUTINE EigenSpectrum(IMatrixDimension, MatrixToBeDiagonalised, EigenValues,&
                    EigenVectors, IErr)

    USE MyNumbers
    USE MyMPI

    IMPLICIT NONE

    INTEGER(IKIND),INTENT(IN) :: IMatrixDimension
    !?? there are no errors for intent(in) but ZGEEV should change it
    COMPLEX(RKIND),INTENT(INOUT) :: MatrixToBeDiagonalised(IMatrixDimension,IMatrixDimension)
    COMPLEX(RKIND),INTENT(OUT) :: EigenValues(IMatrixDimension),&
          EigenVectors(IMatrixDimension,IMatrixDimension)
    INTEGER(IKIND),INTENT(OUT) :: IErr

    INTEGER(IKIND) :: WorkSpaceDimension
    ! dummy vector outputs used while finding respective eigenvectors/values
    COMPLEX(CKIND),DIMENSION(:), ALLOCATABLE :: CWorkSpace 
    REAL(RKIND), DIMENSION(:), ALLOCATABLE :: WorkSpace
    EXTERNAL ZGEEV

    ! find optimum size of arrays
    WorkSpaceDimension=1
    ALLOCATE(CWorkSpace(WorkSpaceDimension),STAT = IErr)
    ALLOCATE(WorkSpace(2*IMatrixDimension),STAT = IErr)
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:EigenSpectrum: error in ALLOCATE() for work arrays (query stage)"
       RETURN
    END IF

    WorkSpaceDimension=-1

    CALL ZGEEV('N','V', IMatrixDimension, MatrixToBeDiagonalised, IMatrixDimension,&
         EigenValues, 0,1, EigenVectors,IMatrixDimension, &
         CWorkSpace, WorkSpaceDimension, WorkSpace, IErr )
    !?? '0,1' constant inputs don't match documentation 
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:EigenSpectrum: error in ZGEEV determining work arrays"
       RETURN
    END IF

    WorkSpaceDimension = INT(CWorkSpace(1))

    ! REALLOCATE necessary memory
    DEALLOCATE(CWorkSpace,STAT=IErr)
    ALLOCATE(CWorkSpace(WorkSpaceDimension),STAT = IErr)
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:EigenSpectrum: error in ALLOCATE() for work arrays (final stage)"
       RETURN
    END IF

    ! do the actual call to get the spectrum
    CALL ZGEEV('N','V', IMatrixDimension, MatrixToBeDiagonalised, IMatrixDimension,&
         EigenValues, 0,1, EigenVectors,IMatrixDimension, &
         CWorkSpace, WorkSpaceDimension, WorkSpace, IErr )
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:EigenSpectrum: error ", IErr, " in ZGEEV"
       RETURN
    ENDIF

    DEALLOCATE(CWorkSpace,STAT = IErr)
    DEALLOCATE(WorkSpace,STAT = IErr)
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:EigenSpectrum: error in DEALLOCATE() for work arrays (final stage)"
       RETURN
    ENDIF

    RETURN

  END SUBROUTINE EigenSpectrum

  !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



  !>
  !! Procedure-description: Invert an M*M Complex Matrix
  !!
  !! Closed procedure, no access to global variables
  !!
  !! Major-Authors: Keith Evans (2014), Richard Beanland (2016)
  !!
  SUBROUTINE INVERT(MatrixSize,Matrix,InvertedMatrix,IErr)  

    !?? called in one place (each iteration), in CreateWavefunctions
    ! Matrix: the Matrix (Destroyed)
    ! InvertedMatrix: the Inverse

    USE MyNumbers
    USE MyMPI
    
    IMPLICIT NONE
    
    INTEGER(IKIND),INTENT(IN) :: MatrixSize
    !?? does this need INOUT as changed here
    COMPLEX(CKIND),INTENT(IN) :: Matrix(MatrixSize,MatrixSize)
    COMPLEX(CKIND),INTENT(OUT) :: InvertedMatrix(1:MatrixSize,1:MatrixSize)
    INTEGER(IKIND),INTENT(OUT) :: IErr

    INTEGER :: LWORK, INFO, I
    INTEGER, DIMENSION(:), ALLOCATABLE :: IPIV
    COMPLEX(CKIND), DIMENSION(:), ALLOCATABLE :: WORK
    
    ALLOCATE(IPIV(MatrixSize),STAT=IErr)
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:Invert(): ERR in ALLOCATE(IPIV(MatrixSize)) statement, MatrixSize=", MatrixSize
       RETURN
    ENDIF
    
    CALL ZGETRF(MatrixSize,MatrixSize,Matrix,MatrixSize,IPIV,IErr)
    LWORK = MatrixSize*MatrixSize
    IF ( IErr.NE.0 ) THEN
       PRINT *,'Error:Invert() : Datatype Error: IFAIL=',INFO
       RETURN
    END IF
    ALLOCATE(WORK(LWORK),STAT=IErr)   
    IF( IErr.NE.0 ) THEN
       PRINT*,"Error:Invert(): ERR in ALLOCATE(WORK(LWORK)) statement, LWORK=", LWORK
       RETURN
    ENDIF
    
    CALL ZGETRI(MatrixSize,Matrix,MatrixSize,IPIV,WORK,LWORK,IErr)
    IF ( IErr.NE.0 ) THEN
       PRINT *,'Error:Inversion Error: IFAIL=',INFO
       RETURN
    END IF
    DEALLOCATE(IPIV,WORK,STAT=IErr)
    IF ( IErr.NE.0 ) THEN
       PRINT *,'Error:Invert : Deallocation Error',INFO
       RETURN
    END IF
    InvertedMatrix = Matrix  
    RETURN

  END SUBROUTINE INVERT

END MODULE bloch_mod
