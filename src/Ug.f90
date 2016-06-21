!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
! felixsim
!
! Richard Beanland, Keith Evans, Rudolf A Roemer and Alexander Hubert
!
! (C) 2013/14, all rights reserved
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
!  This file is part of felixsim.
!
!  felixsim is free software: you can redistribute it and/or modify
!  it under the terms of the GNU General Public License as published by
!  the Free Software Foundation, either version 3 of the License, or
!  (at your option) any later version.
!  
!  felixsim is distributed in the hope that it will be useful,
!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!  GNU General Public License for more details.
!  
!  You should have received a copy of the GNU General Public License
!  along with felixsim.  If not, see <http://www.gnu.org/licenses/>.
!
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

SUBROUTINE GMatrixInitialisation (IErr)

!!$%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!!$%
!!$%   Creates a matrix of every inter G vector (i.e. g1-g2) and
!!$%   their magnitudes 
!!$%
!!$%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
 ! This is now redundant, moved to StructureFactorSetup
  USE MyNumbers
  USE WriteToScreen
  
  USE CConst; USE IConst
  USE IPara; USE RPara

  USE IChannels
  USE MPI
  USE MyMPI
  
  IMPLICIT NONE
  
  INTEGER(IKIND) :: ind,jnd,IErr

  CALL Message("GMatrixInitialisation",IMust,IErr)
  !Ug RgPool is a list of g-vectors in the microscope ref frame, units of 1/A
  ! Note that reciprocal lattice vectors dot not have two pi included, we are using the optical convention exp(2*pi*i*g.r)
  DO ind=1,nReflections
     DO jnd=1,nReflections
        RgMatrix(ind,jnd,:)= RgPool(ind,:)-RgPool(jnd,:)
        RgMatrixMagnitude(ind,jnd)= SQRT(DOT_PRODUCT(RgMatrix(ind,jnd,:),RgMatrix(ind,jnd,:)))
     ENDDO
  ENDDO
  !Ug take the 2 pi back out of the magnitude...   
  RgMatrixMagnitude = RgMatrixMagnitude/TWOPI
  !For symmetry determination, only in Ug refinement
  IF (IRefineMode(1).EQ.1 .OR. IRefineMode(12).EQ.1) THEN
    RgSumMat = SUM(ABS(RgMatrix),3)
  END IF
  
END SUBROUTINE GMatrixInitialisation

!!$%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

SUBROUTINE SymmetryRelatedStructureFactorDetermination (IErr)

!!$%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!!$%
!!$%    Determines which structure factors are related by symmetry, by assuming 
!!$%    that two structure factors with identical absolute values are related
!!$%    (allowing for the hermiticity)
!!$%
!!$%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  !!This is now redundant, moved to SetupUgsToRefine
  USE MyNumbers
  USE WriteToScreen
  
  USE CConst; USE IConst
  USE IPara; USE RPara; USE CPara

  USE IChannels

  USE MPI
  USE MyMPI
    
  IMPLICIT NONE
  
  INTEGER(IKIND) :: ind,jnd,ierr,knd,Iuid
  CHARACTER*200 :: SPrintString

  CALL Message("SymmetryRelatedStructureFactorDetermination",IMust,IErr)

  RgSumMat = RgSumMat+ABS(REAL(CUgMatNoAbs))+ABS(AIMAG(CUgMatNoAbs))

  ISymmetryRelations = 0_IKIND 
  Iuid = 0_IKIND
  
  DO ind = 1,nReflections
     DO jnd = 1,ind
        IF(ISymmetryRelations(ind,jnd).NE.0) THEN
           CYCLE
        ELSE
           Iuid = Iuid + 1_IKIND
           !Ug Fill the symmetry relation matrix with incrementing numbers that have the sign of the imaginary part
		   WHERE (ABS(RgSumMat-RgSumMat(ind,jnd)).LE.RTolerance)
              ISymmetryRelations = Iuid*SIGN(1_IKIND,NINT(AIMAG(CUgMatNoAbs)/TINY**2))
           END WHERE
        END IF
     END DO
  END DO

  IF((IWriteFLAG.GE.0.AND.my_rank.EQ.0).OR.IWriteFLAG.GE.10) THEN
     WRITE(SPrintString,FMT='(I5,A25)') Iuid," unique structure factors"
     PRINT*,TRIM(ADJUSTL(SPrintString))
!     PRINT*,"Unique Ugs = ",Iuid
  END IF
 
  ALLOCATE(IEquivalentUgKey(Iuid),STAT=IErr)
  IF( IErr.NE.0 ) THEN
     PRINT*,"SymmetryRelatedStructureFactorDetermination(",my_rank,")error allocating IEquivalentUgKey"
     RETURN
  END IF
  ALLOCATE(CUgToRefine(Iuid),STAT=IErr)
  IF( IErr.NE.0 ) THEN
     PRINT*,"SymmetryRelatedStructureFactorDetermination(",my_rank,")error allocating CUgToRefine"
     RETURN
  END IF
  
END SUBROUTINE SymmetryRelatedStructureFactorDetermination

!!$%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

SUBROUTINE StructureFactorInitialisation (IErr)

  USE MyNumbers
  USE WriteToScreen

  USE CConst; USE IConst
  USE IPara; USE RPara; USE CPara
  USE BlochPara

  USE IChannels

  USE MPI
  USE MyMPI

  IMPLICIT NONE

  INTEGER(IKIND) :: ind,jnd,knd,lnd,oddindlorentz,evenindlorentz,oddindgauss, &
       evenindgauss,currentatom,IErr
  INTEGER(IKIND),DIMENSION(2) :: IPos,ILoc
  COMPLEX(CKIND) :: CVgij
  REAL(RKIND) :: RMeanInnerPotentialVolts,RAtomicFormFactor,Lorentzian,Gaussian,Kirkland
  CHARACTER*200 :: SPrintString
  
  CALL Message("StructureFactorInitialisation",IMust,IErr)

  CUgMatNoAbs = CZERO

  DO ind=1,nReflections
     DO jnd=1,ind 
        CVgij= 0.0D0
        DO lnd=1,INAtomsUnitCell
           ICurrentAtom = IAtomicNumber(lnd)!Atomic number

           SELECT CASE (IScatterFactorMethodFLAG)! calculate f_e(q) as in Eq. C.15 of Kirkland, "Advanced Computing in EM"

           CASE(0) ! Kirkland Method using 3 Gaussians and 3 Lorentzians
              RAtomicFormFactor = Kirkland(ICurrentAtom,RgMatrixMagnitude(ind,jnd))
!              RAtomicFormFactor = ZERO
!              DO knd = 1,3
!                 !odd and even indicies for Lorentzian function
!                 evenindlorentz = knd*2
!                 oddindlorentz = knd*2 -1
!                 !odd and even indicies for Gaussian function
!                 evenindgauss = evenindlorentz + 6
!                 oddindgauss = oddindlorentz + 6
!                 !Kirkland Method uses summation of 3 Gaussians and 3 Lorentzians (summed in loop)
!                 RAtomicFormFactor = RAtomicFormFactor + &
!                      LORENTZIAN(RScattFactors(ICurrentAtom,oddindlorentz), RgMatrixMagnitude(ind,jnd),ZERO,&
!                      RScattFactors(ICurrentAtom,evenindlorentz))+ &
!                      GAUSSIAN(RScattFactors(ICurrentAtom,oddindgauss),RgMatrixMagnitude(ind,jnd),ZERO, & 
!                      1/(SQRT(2*RScattFactors(ICurrentAtom,evenindgauss))),ZERO)
!              END DO

           CASE(1) ! 8 Parameter Method with Scattering Parameters from Peng et al 1996 
              RAtomicFormFactor = ZERO
              DO knd = 1, 4
                 !Peng Method uses summation of 4 Gaussians
                 RAtomicFormFactor = RAtomicFormFactor + &
                      GAUSSIAN(RScattFactors(ICurrentAtom,knd),RgMatrixMagnitude(ind,jnd),ZERO, & 
                      SQRT(2/RScattFactors(ICurrentAtom,knd+4)),ZERO)
              END DO
			  
           CASE(2) ! 8 Parameter Method with Scattering Parameters from Doyle and Turner Method (1968)
              RAtomicFormFactor = ZERO
              DO knd = 1, 4
                 evenindgauss = knd*2
                 oddindgauss = knd*2 -1
                 !Doyle &Turner uses summation of 4 Gaussians
                 RAtomicFormFactor = RAtomicFormFactor + &
                      GAUSSIAN(RScattFactors(ICurrentAtom,oddindgauss),RgMatrixMagnitude(ind,jnd),ZERO, & 
                      SQRT(2/RScattFactors(ICurrentAtom,evenindgauss)),ZERO)
              END DO

           CASE(3) ! 10 Parameter method with Scattering Parameters from Lobato et al. 2014
              RAtomicFormFactor = ZERO
              DO knd = 1,5
                 evenindlorentz=knd+5
                 RAtomicFormFactor = RAtomicFormFactor + &
                      LORENTZIAN(RScattFactors(ICurrentAtom,knd)* &
                      (TWO+RScattFactors(ICurrentAtom,evenindlorentz)*(RgMatrixMagnitude(ind,jnd)**TWO)), &
                      ONE, &
                      RScattFactors(ICurrentAtom,evenindlorentz)*(RgMatrixMagnitude(ind,jnd)**TWO),ZERO)
              END DO

           END SELECT

           ! initialize potential as in Eq. (6.10) of Kirkland
           RAtomicFormFactor = RAtomicFormFactor*ROccupancy(lnd)
           IF (IAnisoDebyeWallerFactorFlag.EQ.0) THEN
              IF(RIsoDW(lnd).GT.10.OR.RIsoDW(lnd).LT.0) THEN
                 RIsoDW(lnd) = RDebyeWallerConstant
              END IF
              RAtomicFormFactor = RAtomicFormFactor * &
                   EXP(-((RgMatrixMagnitude(ind,jnd)/2.D0)**2)*RIsoDW(lnd))
           ELSE
              RAtomicFormFactor = RAtomicFormFactor * &
                   EXP(-TWOPI*DOT_PRODUCT(RgMatrix(ind,jnd,:), &
                   MATMUL( RAnisotropicDebyeWallerFactorTensor( &
                   RAnisoDW(lnd),:,:), &
                   RgMatrix(ind,jnd,:))))
           END IF
           CVgij = CVgij + RAtomicFormFactor * EXP(-CIMAGONE* &
              DOT_PRODUCT(RgMatrix(ind,jnd,:), RAtomCoordinate(lnd,:)) )
        ENDDO

  CUgMatNoAbs(ind,jnd)=((((TWOPI**2)*RRelativisticCorrection) / &!Ug
             (PI*RVolume))*CVgij)
     ENDDO
  ENDDO

  RMeanInnerCrystalPotential= REAL(CUgMatNoAbs(1,1))!Ug

  !NB Only the lower half of the Ug matrix was calculated, this completes the upper half
  !and also doubles the values on the diagonal
  CUgMatNoAbs = CUgMatNoAbs + CONJG(TRANSPOSE(CUgMatNoAbs))!Ug

  DO ind=1,nReflections!Now halve the diagonal again
     CUgMatNoAbs(ind,ind)=CUgMatNoAbs(ind,ind)-RMeanInnerCrystalPotential!Ug
  ENDDO
  	 
  RMeanInnerPotentialVolts = RMeanInnerCrystalPotential*(((RPlanckConstant**2)/ &
       (TWO*RElectronMass*RElectronCharge*TWOPI**2))*&
       RAngstromConversion*RAngstromConversion)

  CALL Message("StructureFactorInitialisation",IMoreInfo,IErr, &
       MessageVariable = "RMeanInnerCrystalPotential", &
       RVariable = RMeanInnerCrystalPotential)
  CALL Message("StructureFactorInitialisation",IMoreInfo,IErr, &
       MessageVariable = "RMeanInnerPotentialVolts", &
       RVariable = RMeanInnerPotentialVolts)

  !--------------------------------------------------------------------
  ! high-energy approximation (not HOLZ compatible)
  !--------------------------------------------------------------------
  RBigK= SQRT(RElectronWaveVectorMagnitude**2 + RMeanInnerCrystalPotential)
  CALL Message("StructureFactorInitialisation",IInfo,IErr, &
       MessageVariable = "RBigK", RVariable = RBigK)

  !Absorption
  CUgMatPrime = CZERO
    
  SELECT CASE (IAbsorbFLAG)

  CASE(1)

!!$     THE PROPORTIONAL MODEL OF ABSORPTION
     CUgMatPrime = CUgMatNoAbs*EXP(CIMAGONE*PI/2)*(RAbsorptionPercentage/100_RKIND)!Ug
     CUgMat =  CUgMatNoAbs+CUgMatPrime!Ug
	 
  IF(IWriteFLAG.EQ.3.AND.my_rank.EQ.0) THEN
   PRINT*,"Ug matrix, no absorption"
	DO ind =1,8
     WRITE(SPrintString,FMT='(16(1X,F5.2))') CUgMatNoAbs(ind,1:8)
     PRINT*,TRIM(ADJUSTL(SPrintString))
    END DO
  END IF
  
  CASE Default
 
  END SELECT	   
	   
	   
END SUBROUTINE StructureFactorInitialisation

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

SUBROUTINE StructureFactorsWithAbsorption(IErr)         
!RB now redundant, moved into StructureFactorInitialisation

  USE MyNumbers
  USE WriteToScreen
  
  USE CConst; USE IConst
  USE IPara; USE RPara; USE CPara
  USE BlochPara

  USE IChannels

  USE MPI
  USE MyMPI
  
  IMPLICIT NONE 
  
  INTEGER(IKIND) :: IErr,ind
  CHARACTER*200 :: SPrintString

   CALL Message("StructureFactorsWithAbsorption",IMust,IErr)

  CUgMatPrime = CZERO
    
  SELECT CASE (IAbsorbFLAG)

  CASE(1)

!!$     THE PROPORTIONAL MODEL OF ABSORPTION
     
     CUgMatPrime = CUgMatNoAbs*EXP(CIMAGONE*PI/2)*(RAbsorptionPercentage/100_RKIND)!Ug
     CUgMat =  CUgMatNoAbs+CUgMatPrime!Ug
	 
 ! IF(IWriteFLAG.EQ.3.AND.my_rank.EQ.0) THEN
 !   DO ind =1,6
 !    WRITE(SPrintString,FMT='(10(1X,F5.2))') CUgMatNoAbs(ind,1:5)
 !    PRINT*,TRIM(ADJUSTL(SPrintString))
 !   END DO
 ! END IF
  
  CASE Default
 
  END SELECT
  
END SUBROUTINE StructureFactorsWithAbsorption
  
