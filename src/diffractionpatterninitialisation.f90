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

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! $Id: gmodules.f90,v 1.11 2014/03/25 15:37:30 phsht Exp $
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

SUBROUTINE DiffractionPatternInitialisation

  USE WriteToScreen
  USE MyNumbers
  USE IConst

  USE MyMPI

  IMPLICIT NONE

  INTEGER(IKIND) :: IErr

  CALL ReflectionDetermination (IErr)
  IF( IErr.NE.0 ) THEN
     PRINT*,"DiffractionPatternInitialisation(",my_rank,")error", IErr, &
          "in ReflectionDetermination()"
     RETURN
  ENDIF

  CALL SpecificReflectionDetermination (IErr)
  IF( IErr.NE.0 ) THEN
     PRINT*,"DiffractionPatternInitialisation(", my_rank, ") error", IErr, &
          "in SpecificReflectionDetermination()"
     RETURN
  ENDIF

  CALL DiffractionPatternCalculation (IErr)
   IF( IErr.NE.0 ) THEN
     PRINT*,"DiffractionPatternInitialisation(", my_rank, ") error", IErr, &
          "in DiffractionPatternCalculation()"
     RETURN
  ENDIF

  END SUBROUTINE DiffractionPatternInitialisation
  
