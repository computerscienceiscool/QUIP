! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
! H0 X
! H0 X   libAtoms+QUIP: atomistic simulation library
! H0 X
! H0 X   Portions of this code were written by
! H0 X     Albert Bartok-Partay, Silvia Cereda, Gabor Csanyi, James Kermode,
! H0 X     Ivan Solt, Wojciech Szlachta, Csilla Varnai, Steven Winfield.
! H0 X
! H0 X   Copyright 2006-2010.
! H0 X
! H0 X   These portions of the source code are released under the GNU General
! H0 X   Public License, version 2, http://www.gnu.org/copyleft/gpl.html
! H0 X
! H0 X   If you would like to license the source code under different terms,
! H0 X   please contact Gabor Csanyi, gabor@csanyi.net
! H0 X
! H0 X   Portions of this code were written by Noam Bernstein as part of
! H0 X   his employment for the U.S. Government, and are not subject
! H0 X   to copyright in the USA.
! H0 X
! H0 X
! H0 X   When using this software, please cite the following reference:
! H0 X
! H0 X   http://www.libatoms.org
! H0 X
! H0 X  Additional contributions by
! H0 X    Alessio Comisso, Chiara Gattinoni, and Gianpietro Moras
! H0 X
! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X
!X IPModel_Coulomb
!X
!% Coulomb module. Calculates electrostatic interactions between charged
!% species. Supported methods:
!% Direct: the $1/r$ potential
!% Yukawa: Yukawa-screened electrostatic interactions
!% Ewald: Ewald summation technique
!% DSF: Damped Shifted Force Coulomb potential. The interaction is damped by the
!% error function and the potential is force-shifted so both the potential and its
!% derivative goes smoothly to zero at the cutoff. Reference: JCP, 124, 234104 (2006)
!%
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

#include "error.inc"

module IPModel_Coulomb_module

use error_module
use system_module, only : dp, inoutput, print, lower_case, verbosity_push_decrement, verbosity_pop, operator(//), split_string, string_to_int
use periodictable_module, only : total_elements
use dictionary_module
use paramreader_module
use extendable_str_module
use linearalgebra_module
use atoms_types_module
use atoms_module
use units_module

use mpi_context_module
use QUIP_Common_module

use Yukawa_module
use IPEwald_module
use Ewald_module

#ifdef HAVE_GAP
use descriptors_module
use gp_predict_module
#endif

implicit none
private

include 'IPModel_interface.h'

#ifdef GAP_VERSION
   integer, parameter :: gap_version = GAP_VERSION
#else
   integer, parameter :: gap_version = 0
#endif

integer, parameter :: IPCoulomb_Method_Direct = 1
integer, parameter :: IPCoulomb_Method_Yukawa = 2
integer, parameter :: IPCoulomb_Method_Ewald  = 3
integer, parameter :: IPCoulomb_Method_DSF    = 4
integer, parameter :: IPCoulomb_Method_Ewald_NB  = 5

public :: IPModel_Coulomb
type IPModel_Coulomb

  integer :: n_types = 0
  integer, allocatable :: atomic_num(:), type_of_atomic_num(:)
  real(dp), dimension(:), allocatable :: charge
  integer :: method = 0
  integer :: damping = 0
  integer :: screening = 0

  real(dp) :: cutoff = 0.0_dp

  real(dp) :: yukawa_alpha = 0.0_dp
  real(dp) :: yukawa_smooth_length = 0.0_dp
  real(dp) :: yukawa_grid_size = 0.0_dp
  logical :: yukawa_pseudise = .false.

  real(dp) :: ewald_error
  real(dp) :: smooth_coulomb_cutoff

  real(dp) :: dsf_alpha = 0.0_dp

  logical :: use_gp_charges = .false.

  real(dp), dimension(total_elements) :: q0 = 0.0_dp
  integer :: gap_xml_version
#ifdef HAVE_GAP
  type(gpSparse) :: my_gp
  type(descriptor), dimension(:), allocatable :: my_descriptor
#endif

  character(len=STRING_LENGTH) :: label
  character(len=STRING_LENGTH) :: gap_label

endtype IPModel_Coulomb

logical, private :: parse_in_ip, parse_matched_label, parse_gap_params, parse_gap_data
type(IPModel_Coulomb), private, pointer :: parse_ip

interface Initialise
  module procedure IPModel_Coulomb_Initialise_str
end interface Initialise

interface Finalise
  module procedure IPModel_Coulomb_Finalise
end interface Finalise

interface Print
  module procedure IPModel_Coulomb_Print
end interface Print

interface Calc
  module procedure IPModel_Coulomb_Calc
end interface Calc

contains

subroutine IPModel_Coulomb_Initialise_str(this, args_str, param_str)
  type(IPModel_Coulomb), intent(inout) :: this
  character(len=*), intent(in) :: args_str, param_str

  type(Dictionary) :: params
  character(len=STRING_LENGTH) :: method_str
  character(len=STRING_LENGTH) :: gp_label
  logical :: has_method
  integer :: i_coordinate

  call Finalise(this)
  call initialise(params)
  this%label=''
  method_str=''
  call param_register(params, 'label', '', this%label, help_string="No help yet.  This source file was $LastChangedBy$")
  call param_register(params, 'method', '', method_str, help_string="If present, method for Coulomb calculation.  Will be overridden &
      by xml parameters if present", has_value_target=has_method)
  call param_register(params, 'use_gp_charges', 'F', this%use_gp_charges, help_string="Calculate charges from a Gaussian Process model &
      instead of reading from XYZ (must supply an appropriate GAP params string in the XML)")
  call param_register(params, 'charge_gp_label', '', gp_label, help_string="Label for the GP used to compute charges, if using")
  if (.not. param_read_line(params, args_str, ignore_unknown=.true.,task='IPModel_Coulomb_Initialise_str args_str')) then
    call system_abort("IPModel_Coulomb_Initialise_str failed to parse label from args_str="//trim(args_str))
  endif
#ifndef HAVE_GAP
  if (this%use_gp_charges) then
      call system_abort("IPModel_Coulomb_Initialise_str: Must be compiled with GAP support to use GP charges!")
  endif
#endif

  call finalise(params)

  call IPModel_Coulomb_read_params_xml(this, param_str)
  if(this%method == 0) then
     if(has_method) then
        this%method = IPModel_Coulomb_get_method(method_str)
     else
        call system_abort("IPModel_Coulomb_Initialise_str: no method specified either in XML or arguments")
     endif
  endif

  if (this%use_gp_charges) then
     if (this%method /= IPCoulomb_Method_Direct) then
        call system_abort("IPModel_Coulomb_Initialise_str: GP charges only supported for method==direct at the moment")
     endif
     call gp_readXML(this%my_gp, param_str,label=trim(gp_label))
     allocate(this%my_descriptor(this%my_gp%n_coordinate))
     do i_coordinate = 1, this%my_gp%n_coordinate
        call concat(this%my_gp%coordinate(i_coordinate)%descriptor_str," xml_version="//this%gap_xml_version)
        call initialise(this%my_descriptor(i_coordinate), string(this%my_gp%coordinate(i_coordinate)%descriptor_str))
     enddo
  endif

  !  Add initialisation code here

end subroutine IPModel_Coulomb_Initialise_str

function IPModel_Coulomb_get_method(this)
   character(len=*), intent(in) :: this
   integer :: IPModel_Coulomb_get_method

   select case(lower_case(trim(this)))
      case("direct")
         IPModel_Coulomb_get_method = IPCoulomb_Method_Direct
      case("yukawa")
         IPModel_Coulomb_get_method = IPCoulomb_Method_Yukawa
      case("ewald")
         IPModel_Coulomb_get_method = IPCoulomb_Method_Ewald
      case("ewald_nb")
         IPModel_Coulomb_get_method = IPCoulomb_Method_Ewald_NB
      case("dsf")
         IPModel_Coulomb_get_method = IPCoulomb_Method_DSF
      case default
         call system_abort ("IPModel_Coulomb_get_method: method "//trim(this)//" unknown")
   end select

endfunction IPModel_Coulomb_get_method

subroutine IPModel_Coulomb_Finalise(this)
  type(IPModel_Coulomb), intent(inout) :: this

  ! Add finalisation code here

#ifdef HAVE_GAP
  !TODO find out what else we initialized (e.g. descriptors) that we need to clean up
  if (this%my_gp%initialised) call finalise(this%my_gp)
  if (allocated(this%my_descriptor)) deallocate(this%my_descriptor)
#endif
  if (allocated(this%atomic_num)) deallocate(this%atomic_num)
  if (allocated(this%type_of_atomic_num)) deallocate(this%type_of_atomic_num)
  if (allocated(this%charge)) deallocate(this%charge)

  this%n_types = 0
  this%label = ''
  this%cutoff = 0.0_dp
  this%method = 0

end subroutine IPModel_Coulomb_Finalise

recursive subroutine IPModel_Coulomb_Calc(this, at, e, local_e, f, virial, local_virial, args_str, mpi, error)
   type(IPModel_Coulomb), intent(inout):: this
   type(Atoms), intent(inout)  :: at
   real(dp), intent(out), optional :: e, local_e(:)
   real(dp), intent(out), optional :: f(:,:), local_virial(:,:)   !% Forces, dimensioned as \texttt{f(3,at%N)}, local virials, dimensioned as \texttt{local_virial(9,at%N)}
   real(dp), intent(out), optional :: virial(3,3)
   character(len=*), optional      :: args_str
   type(MPI_Context), intent(in), optional :: mpi
   integer, intent(out), optional :: error

   type(Dictionary) :: params
   real(dp), dimension(:), allocatable, target :: my_charge
   real(dp), dimension(:), pointer :: charge
   real(dp), dimension(:,:), allocatable :: dummy_force
   real(dp) :: r_scale, E_scale, e_pre_calc, charge_no_cutoff
   logical :: do_rescale_r, do_rescale_E, do_pairwise_by_Z,do_e, do_f, do_grads, do_print_charges

   real(dp), pointer :: local_e_by_Z(:,:), local_e_contrib(:)
   integer, allocatable :: Z_s(:), Z_u(:)
   integer :: n_uniq_Zs, i_coordinate, i_desc, neigh_idx
   type(charge_gradients), dimension(:), allocatable :: charge_grads
   real(dp), allocatable :: grad_coeffs(:)
   real(dp) :: charge_grad_contrib(3)

   type(descriptor_data) :: my_descriptor_data

   real(dp), allocatable :: gamma_mat(:,:)

   integer :: i, i_Z, ddims

   character(len=STRING_LENGTH) :: charge_property_name, atom_mask_name, source_mask_name

   INIT_ERROR(error)
   do_f=present(f)
   do_e=present(e)

   if (do_e) e = 0.0_dp
   if (present(local_e)) then
      call check_size('Local_E',local_e,(/at%N/),'IPModel_Coulomb_Calc', error)
      local_e = 0.0_dp
   endif
   if (do_f) then
      call check_size('Force',f,(/3,at%Nbuffer/),'IPModel_Coulomb_Calc', error)
      f = 0.0_dp
   end if
   if (present(virial)) virial = 0.0_dp
   if (present(local_virial)) then
      call check_size('Local_virial',local_virial,(/9,at%Nbuffer/),'IPModel_Coulomb_Calc', error)
      local_virial = 0.0_dp
   endif

   if (present(args_str)) then
      call initialise(params)
      call param_register(params, 'charge_property_name', 'charge', charge_property_name, help_string="No help yet.  This source file was $LastChangedBy$")
      call param_register(params, 'atom_mask_name', '', atom_mask_name, help_string="No help yet.  This source file was $LastChangedBy$")
      call param_register(params, 'source_mask_name', '', source_mask_name, help_string="No help yet.  This source file was $LastChangedBy$")
      call param_register(params, 'r_scale', '1.0',r_scale, has_value_target=do_rescale_r, help_string="Rescaling factor for distances. Default 1.0.")
      call param_register(params, 'E_scale', '1.0',E_scale, has_value_target=do_rescale_E, help_string="Rescaling factor for energy. Default 1.0.")
      call param_register(params, 'pairwise_by_Z', 'F',do_pairwise_by_Z, help_string="If true, calculate pairwise contributions to local_e broken down by Z")
      call param_register(params, 'print_charge_prediction', 'F', do_print_charges, help_string="Print the predicted charges to stdout")

      if (.not. param_read_line(params, args_str, ignore_unknown=.true.,task='IPModel_Coulomb_Calc args_str')) then
         RAISE_ERROR("IPModel_Coulomb_Calc failed to parse args_str="//trim(args_str), error)
      endif
      call finalise(params)
      if (do_rescale_r ) then
         RAISE_ERROR("IPModel_Coulomb_Calc: rescaling of potential with r_scale not yet implemented!", error)
      end if
   else
      charge_property_name = 'charge'
   endif

   if(has_property(at,charge_property_name)) then
      if(.not. assign_pointer(at, charge_property_name, charge)) then
         RAISE_ERROR('IPModel_Coulomb_Calc failed to assign pointer to '//trim(charge_property_name)//' property', error)
      endif
#ifdef HAVE_GAP
   elseif (this%use_gp_charges) then
      !TODO put all this in a subroutine
      allocate(my_charge(at%N))
      charge => my_charge
      do i = 1, at%N
         charge(i) = this%q0(at%Z(i))
      end do
      ! Initialize charges from GP
      ! Would be better placed in a new subroutine tbh
      ! First construct the gradients object, if we need it
      do_grads = present(f) .or. present(virial) .or. present(local_virial)
      if (do_grads) then
         allocate(charge_grads(at%N))
      end if
      do i_coordinate = 1, this%my_gp%n_coordinate
         ddims = descriptor_dimensions(this%my_descriptor(i_coordinate))
         !TODO check preprocessing on the args_str above
         call calc(this%my_descriptor(i_coordinate), at, my_descriptor_data, &
           do_descriptor=.true., do_grad_descriptor=do_grads, &
           args_str=trim(args_str), error=error)
         if (do_grads) then
            if (allocated(grad_coeffs)) deallocate(grad_coeffs)
            allocate(grad_coeffs(ddims))
            do i_desc = 1, size(my_descriptor_data%x)
               if( size(my_descriptor_data%x(i_desc)%ci) /= 1 ) then
                  RAISE_ERROR("IPModel_Coulomb_Calc: descriptor is not local and atomic",error)
               end if
               i = my_descriptor_data%x(i_desc)%ci(1)
               charge_grads(i)%neigh_lo = lbound(my_descriptor_data%x(i_desc)%ii, 1)
               charge_grads(i)%neigh_up = ubound(my_descriptor_data%x(i_desc)%ii, 1)
               allocate(charge_grads(i)%gradients(3, charge_grads(i)%neigh_lo : charge_grads(i)%neigh_up))
               allocate(charge_grads(i)%neigh_idx(charge_grads(i)%neigh_lo : charge_grads(i)%neigh_up))
               charge_grads(i)%neigh_idx = my_descriptor_data%x(i_desc)%ii
               charge_grads(i)%gradients = 0.0_dp

               ! Now predict the charges and their gradients
               ! Don't need to re-zero grad_coeffs since the gp_predict routine
               ! effectively ignores its value anyway
               charge_no_cutoff = gp_predict(this%my_gp%coordinate(i_coordinate), &
                  xStar=my_descriptor_data%x(i_desc)%data(:), gradPredict=grad_coeffs)
               charge(i) = charge(i) + charge_no_cutoff * my_descriptor_data%x(i_desc)%covariance_cutoff
               do neigh_idx = charge_grads(i)%neigh_lo, charge_grads(i)%neigh_up
                  if( .not. my_descriptor_data%x(i_desc)%has_grad_data(neigh_idx) ) cycle
                  charge_grad_contrib = matmul(grad_coeffs, my_descriptor_data%x(i_desc)%grad_data(:,:,neigh_idx)) &
                     * my_descriptor_data%x(i_desc)%covariance_cutoff &
                     + charge_no_cutoff * my_descriptor_data%x(i_desc)%grad_covariance_cutoff(:,neigh_idx)
                  charge_grads(i)%gradients(:,neigh_idx) = charge_grads(i)%gradients(:,neigh_idx) + charge_grad_contrib
               end do
            end do
         else
            ! Really...? We still have to iterate explicitly over the coordinates, when
            ! in principle this is just a plain matrix multiplication??
            do i_desc = 1, size(my_descriptor_data%x)
               charge(i) = charge(i) + gp_predict(this%my_gp%coordinate(i_coordinate), &
                     xStar=my_descriptor_data%x(i_desc)%data(:)) &
                  * my_descriptor_data%x(i_desc)%covariance_cutoff
            end do
         end if
         call finalise(my_descriptor_data)
         if (allocated(grad_coeffs)) deallocate(grad_coeffs)
      end do
      if (do_print_charges) call print ("Predicted charges: " // my_charge(:))
#endif
   else
      allocate(my_charge(at%N))
      charge => my_charge
      charge = 0.0_dp
      do i = 1, at%N
         charge(i) = this%charge(this%type_of_atomic_num(at%Z(i)))
      enddo
   endif


   selectcase(this%method)
   case(IPCoulomb_Method_Direct)
      call Direct_Coulomb_calc(at, charge, e=e, f=f, virial=virial, error = error)
   case(IPCoulomb_Method_Yukawa)
      call yukawa_charges(at, charge, this%cutoff, this%yukawa_alpha, this%yukawa_smooth_length, &
      e, local_e, f, virial, &
      mpi=mpi, atom_mask_name=atom_mask_name, source_mask_name=source_mask_name, type_of_atomic_num=this%type_of_atomic_num, &
      pseudise=this%yukawa_pseudise, grid_size=this%yukawa_grid_size, error=error)
   case(IPCoulomb_Method_Ewald)
      call Ewald_calc(at, charge, e, f, virial, ewald_error=this%ewald_error, use_ewald_cutoff=.false., smooth_coulomb_cutoff=this%smooth_coulomb_cutoff, error=error)
   case(IPCoulomb_Method_Ewald_NB)
      if (present(f) .or. present(virial) .or. present(local_virial)) then
         RAISE_ERROR("IPModel_Coulomb_Calc: method ewald_nb doesn't have F or V implemented yet", error)
      endif
      allocate(gamma_mat(at%n,at%n))
      gamma_mat = 0.0_dp
      call add_madelung_matrix(at%N, at%lattice(:,1), at%lattice(:,2), at%lattice(:,3), at%pos, gamma_mat, redo_lattice=.true.)
call print("gamma_mat")
call print(gamma_mat)
      if (present(e)) e = 0.5_dp*sum(charge*matmul(gamma_mat, charge))
      if (present(local_e)) local_e = 0.5_dp*charge*matmul(gamma_mat, charge)
      if (do_pairwise_by_Z) then
         allocate(Z_s(at%n))
         Z_s = at%Z
         call sort_array(Z_s)
         call uniq(Z_s, Z_u)
         deallocate(Z_s)

call print("local_pot "//matmul(gamma_mat, charge))

         n_uniq_Zs = size(Z_u)
         if (has_property(at, "local_e_pairwise_by_Z")) call remove_property(at, "local_e_pairwise_by_Z")
         call add_property(at, "local_e_pairwise_by_Z", 0.0_dp, n_cols=n_uniq_Zs, ptr2 = local_e_by_Z)
         allocate(local_e_contrib(at%N))
         do i=1, at%N
            local_e_contrib = 0.5_dp * gamma_mat(i,:) * charge(:) * charge(i)
call print("local_e_contrib "//i //" "//local_e_contrib)
            do i_Z = 1, n_uniq_Zs
               local_e_by_Z(i_Z,i) = sum(local_e_contrib, mask=(at%Z == Z_u(i_Z)))
            end do
         end do
         deallocate(local_e_contrib)

      endif
      deallocate(gamma_mat)
   case(IPCoulomb_Method_DSF)
      call DSF_Coulomb_calc(at, charge, this%DSF_alpha, e=e, local_e=local_e, f=f, virial=virial, cutoff=this%cutoff, error = error)
   case default
      RAISE_ERROR("IPModel_Coulomb_Calc: unknown method", error)
   endselect


   charge => null()
   if(allocated(my_charge)) deallocate(my_charge)

   if (do_rescale_E) then
      if (present(e)) e = e*E_scale
      if (present(local_e)) local_e = local_e*E_scale
      if (present(f)) f = f*E_scale
      if (present(virial)) virial=virial*E_scale
      if (present(local_virial)) local_virial=local_virial*E_scale
   end if

end subroutine IPModel_Coulomb_Calc


subroutine IPModel_Coulomb_Print(this, file)
  type(IPModel_Coulomb), intent(in) :: this
  type(Inoutput), intent(inout),optional :: file

  integer :: ti , tj

  call Print("IPModel_Coulomb : Coulomb Potential", file=file)
  select case(this%method)
  case(IPCoulomb_Method_Direct)
     call Print("IPModel_Coulomb method: Direct")
  case(IPCoulomb_Method_Yukawa)
     call Print("IPModel_Coulomb method: Yukawa")
  case(IPCoulomb_Method_Ewald)
     call Print("IPModel_Coulomb method: Ewald")
  case(IPCoulomb_Method_Ewald_NB)
     call Print("IPModel_Coulomb method: Ewald_NB")
  case(IPCoulomb_Method_DSF)
     call Print("IPModel_Coulomb method: Damped Shifted Force Coulomb")
  case default
     call system_abort ("IPModel_Coulomb: method identifier "//this%method//" unknown")
  endselect

  call Print("IPModel_Coulomb : n_types = " // this%n_types // " cutoff = " // this%cutoff, file=file)

  do ti=1, this%n_types
    call Print ("IPModel_Coulomb : type " // ti // " atomic_num " // this%atomic_num(ti), file=file)
    call verbosity_push_decrement()
    call Print ("IPModel_Coulomb : " // &
        "cutoff " // this%cutoff , &
         file=file)
    call verbosity_pop()
  end do

end subroutine IPModel_Coulomb_Print

subroutine IPModel_Coulomb_read_params_xml(this, param_str)
  type(IPModel_Coulomb), intent(inout), target :: this
  character(len=*), intent(in) :: param_str

  type(xml_t) :: fxml

  if (len(trim(param_str)) <= 0) return

  parse_in_ip = .false.
  parse_matched_label = .false.
  parse_gap_params = .false.
  parse_gap_data = .false.
  parse_ip => this
  call open_xml_string(fxml, param_str)
  call parse(fxml,  &
    startElement_handler = IPModel_startElement_handler, &
    endElement_handler = IPModel_endElement_handler)
  call close_xml_t(fxml)

  if (this%n_types == 0 ) then
    call system_abort("IPModel_Coulomb_read_params_xml parsed file, but n_types = 0 ")
  endif

end subroutine IPModel_Coulomb_read_params_xml

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X
!% XML param reader functions
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
subroutine IPModel_startElement_handler(URI, localname, name, attributes)
  character(len=*), intent(in)   :: URI
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name
  type(dictionary_t), intent(in) :: attributes

  integer :: status

  character(len=STRING_LENGTH) :: value, signature_string, pos_type_str
  character(len=STRING_LENGTH), dimension(99) :: signature_fields

  logical :: energy_shift, linear_force_shift
  integer :: ti, tj, i ,n_atoms, Z
  real(dp) :: alpha_au

  if (name == 'Coulomb_params') then ! new Coulomb stanza

    if (parse_matched_label) return ! we already found an exact match for this label

    call QUIP_FoX_get_value(attributes, 'label', value, status)
    if (status /= 0) value = ''

    if (len(trim(parse_ip%label)) > 0) then ! we were passed in a label
      if (trim(value) == trim(parse_ip%label)) then ! exact match
        parse_matched_label = .true.
        parse_in_ip = .true.
      else ! no match
        parse_in_ip = .false.
      endif
    else ! no label passed in
      parse_in_ip = .true.
    endif

    if (parse_in_ip) then
      if (parse_ip%n_types /= 0) then
        call finalise(parse_ip)
      endif

      call QUIP_FoX_get_value(attributes, 'method', value, status)
      if (status == 0) then
        parse_ip%method = IPModel_Coulomb_get_method(value)
      endif

      call QUIP_FoX_get_value(attributes, 'n_types', value, status)
      if (status == 0) then
        read (value, *) parse_ip%n_types
      else
        call system_abort("Can't find n_types in Coulomb_params")
      endif

      allocate(parse_ip%atomic_num(parse_ip%n_types))
      parse_ip%atomic_num = 0

      allocate(parse_ip%charge(parse_ip%n_types))
      parse_ip%charge = 0.0_dp

      call QUIP_FoX_get_value(attributes, "cutoff", value, status)
      if (status /= 0) call system_abort ("IPModel_Coulomb_read_params_xml cannot find cutoff")
      read (value, *) parse_ip%cutoff


      call QUIP_FoX_get_value(attributes, "yukawa_alpha", value, status)
      if (status /= 0) then
         if( parse_ip%method == IPCoulomb_Method_Yukawa ) call system_abort("IPModel_Coulomb_read_params_xml: Yukawa method requested but no yukawa_alpha parameter found.")
      else
         read (value, *) parse_ip%yukawa_alpha
      endif

      call QUIP_FoX_get_value(attributes, "yukawa_smooth_length", value, status)
      if (status == 0) then
         read (value, *) parse_ip%yukawa_smooth_length
      else
         parse_ip%yukawa_smooth_length = 0.0_dp
      endif

      call QUIP_FoX_get_value(attributes, "yukawa_pseudise", value, status)
      if (status == 0) then
         read (value, *) parse_ip%yukawa_pseudise
      else
         parse_ip%yukawa_pseudise = .false.
      endif

      call QUIP_FoX_get_value(attributes, "yukawa_grid_size", value, status)
      if (status == 0) then
         read (value, *) parse_ip%yukawa_grid_size
      else
         parse_ip%yukawa_grid_size = 0.0_dp
      endif

      call QUIP_FoX_get_value(attributes, "ewald_error", value, status)
      if (status == 0) then
         read (value, *) parse_ip%ewald_error
      else
         parse_ip%ewald_error = 1.0e-6_dp
      endif

      call QUIP_FoX_get_value(attributes, "smooth_coulomb_cutoff", value, status)
      if (status == 0) then
         read (value, *) parse_ip%smooth_coulomb_cutoff
      else
         parse_ip%smooth_coulomb_cutoff = 0.0_dp
      endif

      call QUIP_FoX_get_value(attributes, "dsf_alpha", value, status)
      if (status /= 0) then
         if( parse_ip%method == IPCoulomb_Method_DSF ) call system_abort("IPModel_Coulomb_read_params_xml: Damped Shifted Force method requested but no dsf_alpha parameter found.")
      else
         read (value, *) parse_ip%dsf_alpha
      endif

    endif

  elseif (parse_in_ip .and. name == 'per_type_data') then

    call QUIP_FoX_get_value(attributes, "type", value, status)
    if (status /= 0) call system_abort ("IPModel_Coulomb_read_params_xml cannot find type")
    read (value, *) ti

    call QUIP_FoX_get_value(attributes, "atomic_num", value, status)
    if (status /= 0) call system_abort ("IPModel_Coulomb_read_params_xml cannot find atomic_num")
    read (value, *) parse_ip%atomic_num(ti)

    call QUIP_FoX_get_value(attributes, "charge", value, status)
    if (status /= 0) call system_abort ("IPModel_Coulomb_read_params_xml cannot find charge")
    read (value, *) parse_ip%charge(ti)

    if (allocated(parse_ip%type_of_atomic_num)) deallocate(parse_ip%type_of_atomic_num)
    allocate(parse_ip%type_of_atomic_num(maxval(parse_ip%atomic_num)))
    parse_ip%type_of_atomic_num = 0
    do ti=1, parse_ip%n_types
      if (parse_ip%atomic_num(ti) > 0) &
        parse_ip%type_of_atomic_num(parse_ip%atomic_num(ti)) = ti
    end do

  elseif (name == "GAP_params") then
     call QUIP_FoX_get_value(attributes, 'label', value, status)
     if (status /= 0) value = ''
     !TODO check that this matches the GAP label given in the init_args
     parse_ip%gap_label = trim(value)

     call QUIP_FoX_get_value(attributes, 'gap_version', value, status)
     if (status == 0) then
        parse_ip%gap_xml_version = string_to_int(value)
        if (parse_ip%gap_xml_version > gap_version) &
        call system_abort( &
           'Database was created with a later version of the code.' // &
           'Version of code used to generate the database is '//trim(value)//'.'// &
           'Version of current code is '//gap_version//'. Please update your code.')
     else
        parse_ip%gap_xml_version = 0
     endif
     parse_gap_params = .true.
  elseif (name == "GAP_data" .and. parse_gap_params) then
     call QUIP_FoX_get_value(attributes, 'e0', value, status)
     ! Supplied one e0 (aka q0) for the whole fit
     if(status == 0) then
        read (value, *) parse_ip%q0(1)
        parse_ip%q0 = parse_ip%q0(1)
     endif
     parse_gap_data = .true.
  elseif (name == "e0" .and. parse_gap_data) then
     ! Per-species e0/q0 data
     call QUIP_FoX_get_value(attributes, 'Z', value, status)
     if(status == 0) then
        read (value, *) Z
     else
        call system_abort('IPModel_vdW_read_params_xml cannot find Z')
     endif
     if( Z > size(parse_ip%q0) ) call system_abort('IPModel_vdW_read_params_xml: attribute Z = '//Z//' > '//size(parse_ip%q0))

     call QUIP_FoX_get_value(attributes, 'value', value, status)
     if(status == 0) then
        read (value, *) parse_ip%q0(Z)
     else
        call system_abort('IPModel_vdW_read_params_xml cannot find value in e0')
     endif
  endif


end subroutine IPModel_startElement_handler

subroutine IPModel_endElement_handler(URI, localname, name)
  character(len=*), intent(in)   :: URI
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name

  if (parse_in_ip) then
    if (name == 'Coulomb_params') then
      parse_in_ip = .false.
    end if
  endif
  if (parse_gap_params) then
    if (name == 'GAP_params') then
      parse_gap_params = .false.
    end if
  end if
  if (parse_gap_data) then
    if (name == 'GAP_data') then
      parse_gap_data = .false.
    end if
  end if

end subroutine IPModel_endElement_handler

end module IPModel_Coulomb_module
