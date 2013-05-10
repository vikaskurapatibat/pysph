# Cython
cimport cython

# Numpy
import numpy as np
cimport numpy as np

# MPI4PY
import mpi4py.MPI as mpi

# PyZoltan
from pyzoltan.czoltan cimport czoltan
from pyzoltan.czoltan.czoltan cimport Zoltan_Struct
from pyzoltan.core import zoltan_utils

# PySPH imports
from pysph.base.nnps cimport DomainLimits, Cell

# local imports
import parallel_utils
from parallel_utils import ParticleTAGS

cdef extern from 'math.h':
    int abs(int)
    cdef double ceil(double)
    cdef double floor(double)
    cdef double fabs(double)

cdef extern from 'limits.h':
    cdef int INT_MAX
    cdef unsigned int UINT_MAX

cdef inline int real_to_int(double real_val, double step):
    """ Return the bin index to which the given position belongs.

    Parameters:
    -----------
    val -- The coordinate location to bin
    step -- the bin size    

    Example:
    --------
    real_val = 1.5, step = 1.0 --> ret_val = 1

    real_val = -0.5, step = 1.0 --> real_val = -1
    
    """
    cdef int ret_val = <int>floor( real_val/step )

    return ret_val

cdef inline cIntPoint find_cell_id(cPoint pnt, double cell_size):
    """ Find the cell index for the corresponding point 

    Parameters:
    -----------
    pnt -- the point for which the index is sought
    cell_size -- the cell size to use
    id -- output parameter holding the cell index 

    Algorithm:
    ----------
    performs a box sort based on the point and cell size

    Notes:
    ------
    Uses the function  `real_to_int`
    
    """
    cdef cIntPoint p = cIntPoint(real_to_int(pnt.x, cell_size),
                                 real_to_int(pnt.y, cell_size),
                                 0)
    return p

cdef inline cPoint _get_centroid(double cell_size, cIntPoint cid):
        """ Get the centroid of the cell.

        Parameters:
        -----------

        cell_size : double (input)
            Cell size used for binning

        cid : cPoint (input)
            Spatial index for a cell

        Returns:
        ---------
        
        centroid : cPoint 
             
        Notes:
        ------
        The centroid in any coordinate direction is defined to be the
        origin plus half the cell size in that direction

        """
        centroid = cPoint_new(0.0, 0.0, 0.0)
        centroid.x = (<double>cid.x + 0.5)*cell_size
        centroid.y = (<double>cid.y + 0.5)*cell_size

        return centroid

def get_centroid(double cell_size, IntPoint cid):
    """ Get the centroid of the cell.
    
    Parameters:
    -----------
    
    cell_size : double (input)
        Cell size used for binning
    
    cid : IntPoint (input)
        Spatial index for a cell
    
    Returns:
    ---------
    
    centroid : Point 
    
    Notes:
    ------
    The centroid in any coordinate direction is defined to be the
    origin plus half the cell size in that direction
    
    """
    cdef cPoint _centroid = _get_centroid(cell_size, cid.data)
    centroid = Point_new(0.0, 0.0, 0.0)

    centroid.data = _centroid
    return centroid

cpdef UIntArray arange_uint(int start, int stop=-1):
    """Utility function to return a numpy.arange for a UIntArray"""
    cdef int size
    cdef UIntArray arange
    cdef int i = 0

    if stop == -1:
        arange = UIntArray(start)
        for i in range(start):
            arange.data[i] = <unsigned int>i
    else:
        size = stop-start
        arange = UIntArray(size)
        for i in range(size):
            arange.data[i] = <unsigned int>(start + i)

    return arange

cdef class ParticleArrayWrapper:
    def __init__(self, ParticleArray pa):
        self.pa = pa
        self.name = pa.name

        # set up the load balancing props for the particle array
        self.x = pa.get_carray('x')
        self.y = pa.get_carray('y')
        self.z = pa.get_carray('z')

        self.ax = pa.get_carray('ax')
        self.ay = pa.get_carray('ay')
        self.az = pa.get_carray('az')

        self.u = pa.get_carray('u')
        self.v = pa.get_carray('v')
        self.w = pa.get_carray('w')

        self.au = pa.get_carray('au')
        self.av = pa.get_carray('av')
        self.aw = pa.get_carray('aw')

        self.rho = pa.get_carray('rho')
        self.arho = pa.get_carray('arho')
        
        self.h = pa.get_carray('h')
        self.m = pa.get_carray('m')

        self.gid = pa.get_carray('gid')
        self.tag = pa.get_carray('tag')

################################################################
# ParticleArrayExchange
################################################################w
cdef class ParticleArrayExchange:
    def __init__(self, ParticleArray pa, object comm, lb_props=None):
        self.pa = pa

        self.pa_wrapper = ParticleArrayWrapper( pa )

        self.comm = comm
        self.rank = comm.Get_rank()
        self.size = comm.Get_size()

        # num particles
        self.num_local = pa.get_number_of_particles()
        self.num_remote = 0
        self.num_global = 0
        self.num_ghost = 0

        # Particle Import/Export lists
        self.exportParticleGlobalids = UIntArray()
        self.exportParticleLocalids = UIntArray()
        self.exportParticleProcs = IntArray()
        self.numParticleExport = 0

        self.importParticleGlobalids = UIntArray()
        self.importParticleLocalids = UIntArray()
        self.importParticleProcs = IntArray()
        self.numParticleImport = 0

        # load balancing props
        if lb_props is None:
            self.lb_props = ['x','y', 'z', 'ax', 'ay', 'az',
                             'u', 'v', 'w', 'au', 'av', 'aw',
                             'rho', 'arho', 
                             'm', 'h', 'gid', 'tag']
        else:
            self.lb_props = lb_props

        # temporary buffers
        self.uintbuf = UIntArray()
        self.intbuf = IntArray()
        self.doublebuf = DoubleArray()
        self.longbuf = LongArray()

    def lb_exchange_data(self):
        """Share particle info after Zoltan_LB_Balance

        After an initial call to 'Zoltan_LB_Balance', the new size of
        the arrays should be (num_particles - numExport + numImport)
        to reflect particles that should be imported and exported.

        This function should be called after the load balancing lists
        a defined. The particles to be exported are removed and the
        arrays re-sized. MPI is then used to send and receive the data

        """
        # data array
        cdef ParticleArray pa = self.pa
        
        # Zoltan generated lists
        cdef UIntArray exportGlobalids = self.exportParticleGlobalids
        cdef UIntArray exportLocalids = self.exportParticleLocalids
        cdef IntArray exportProcs = self.exportParticleProcs
        cdef int numExport = self.numParticleExport

        cdef UIntArray importGlobalids = self.importParticleGlobalids
        cdef UIntArray importLocalids = self.importParticleLocalids
        cdef IntArray importProcs = self.importParticleProcs
        cdef int numImport = self.numParticleImport

        # dicts to send/recv data 
        cdef dict recv = {}

        # collect the data to send
        cdef dict send = parallel_utils.get_send_data(self.comm, pa, self.lb_props, exportLocalids,
                                                  exportProcs)

        # current number of particles
        cdef int current_size = self.num_local
        cdef int count, new_size

        # MPI communicator
        cdef object comm = self.comm

        # count the number of objects to receive from remote procesors
        parallel_utils.count_recv_data(comm, recv, numImport, importProcs)

        # Remove particles to be exported
        pa.remove_particles( exportLocalids )

        # resize the arrays
        newsize = current_size - numExport + numImport
        count = current_size - numExport

        pa.resize( newsize )
        self.set_tag(count, newsize, 0)
        
        # exchange the data
        self._exchange_data(count, send, recv)

        # update the number of particles
        self.num_local = newsize

    def remote_exchange_data(self):
        """Share particle info after computing remote particles.

        After a load balancing and the corresponding exhange of
        particles, additional particles are needed as remote
        (remote). Calls to 'compute_remote_particles' and
        'Zoltan_Invert_Lists' builds the lists required.

        The arrays must now be re-sized to (num_particles + numImport)
        to reflect the new particles that come in as remote particles.

        """
        # data arrays
        cdef ParticleArray pa = self.pa
        
        # Import/Export lists
        cdef UIntArray exportGlobalids = self.exportParticleGlobalids
        cdef UIntArray exportLocalids = self.exportParticleLocalids
        cdef IntArray exportProcs = self.exportParticleProcs

        cdef UIntArray importGlobalids = self.importParticleGlobalids
        cdef UIntArray importLocalids = self.importParticleLocalids
        cdef IntArray importProcs = self.importParticleProcs
        cdef int numImport = self.numParticleImport

        # collect the data to send
        cdef dict recv = {}
        cdef dict send = parallel_utils.get_send_data(
            self.comm, pa, self.lb_props, exportLocalids,exportProcs)

        # current number of particles
        cdef int current_size = self.num_local
        cdef int count, new_size

        # MPI communicator
        cdef object comm = self.comm

        # count the number of objects to receive from remote procesors
        parallel_utils.count_recv_data(comm, recv, numImport, importProcs)

        # resize the arrays
        newsize = current_size + numImport
        count = current_size

        pa.resize( newsize )
        self.set_tag(count, newsize, 0)

        # share the data
        self._exchange_data(count, send, recv)

        # store the number of remote particles
        self.num_remote = newsize - current_size

    cdef _exchange_data(self, int count, dict send, dict recv):
        """New send and receive."""
        # data arrays
        cdef ParticleArray pa = self.pa

        # MPI communicator
        cdef object comm = self.comm

        # temp buffers to store info
        cdef DoubleArray doublebuf = self.doublebuf
        cdef UIntArray uintbuf = self.uintbuf
        cdef LongArray longbuf = self.longbuf
        cdef IntArray intbuf = self.intbuf

        cdef int rank = self.rank
        cdef int size = self.size
        cdef int i, j

        ctype_map = {'unsigned int':uintbuf,
                     'double':doublebuf,
                     'long':longbuf,
                     'int':intbuf}

        props = {}
        for prop in self.lb_props:
            prop_array = pa.get_carray(prop)
            props[ prop ] = ctype_map[ prop_array.get_c_type() ]
            
        ############### SEND AND RECEIVE START ########################
        # Receive from processors with a lower rank
        for i in recv.keys():
            if i < rank:
                for prop, recvbuf in props.iteritems():
                    recvbuf.resize( recv[i] )

                    parallel_utils.Recv(comm=comm,
                                    localbuf=pa.get_carray(prop),
                                    localbufsize=count,
                                    recvbuf=recvbuf,
                                    source=i)
                
                # update the local buffer size
                count = count + recv[i]

        # Send the data across
        for pid in send.keys():
            for prop in props:
                sendbuf = send[pid][prop]
                comm.Send( sendbuf, dest=pid )
                    
        # recv from procs with higher rank i value as set in first loop
        for i in recv.keys():
            if i > rank:
                for prop, recvbuf in props.iteritems():
                    recvbuf.resize( recv[i] )

                    parallel_utils.Recv(comm=comm,
                                    localbuf=pa.get_carray(prop),
                                    localbufsize=count,
                                    recvbuf=recvbuf,
                                    source=i)

                # update to the new length
                count = count + recv[i]

        ############### SEND AND RECEIVE STOP ########################

    def remove_remote_particles(self):
        cdef int num_local = self.num_local

        # resize the particle array
        self.pa.resize( num_local )
        self.pa.align_particles()
        
        # reset the number of remote particles
        self.num_remote = 0

    def align_particles(self):
        self.pa.align_particles()

    def set_tag(self, int start, int end, int value):
        """Reset the annoying tag value after particles are resized."""
        cdef int i
        cdef IntArray tag = self.pa_wrapper.tag

        for i in range(start, end):
            tag[i] = value

    def update_particle_gids(self):
        """Update the global indices.

        We call a utility function to get the new number of particles
        across the processors and then linearly assign indices to the
        objects.

        """
        cdef int num_global_objects, num_local_objects, _sum, i
        cdef np.ndarray[ndim=1, dtype=np.int32_t] num_objects_data

        # the global indices array
        cdef UIntArray gid = self.pa_wrapper.gid

        cdef object comm = self.comm
        cdef int rank = self.rank
        cdef int size = self.size

        num_objects_data = zoltan_utils.get_num_objects_per_proc(
            comm, self.num_local)
        
        num_local_objects = num_objects_data[ rank ]
        num_global_objects = np.sum( num_objects_data )

        _sum = np.sum( num_objects_data[:rank] )

        gid.resize( num_local_objects )
        for i in range( num_local_objects ):
            gid.data[i] = <ZOLTAN_ID_TYPE> ( _sum + i )

        # set the number of local and global objects
        self.num_global = num_global_objects

# #################################################################
# # ParallelManager extension classes
# #################################################################
cdef class ParallelManager:
    """Base class for all parallel managers."""
    def __init__(self, int dim, list particles, object comm,
                 double radius_scale=2.0,
                 int ghost_layers=2, domain=None,
                 lb_props=None):
        """Constructor.

        Parameters:
        -----------

        dim : int
            Dimension

        particles : list
            list of particle arrays to be managed.

        comm : mpi4py.MPI.COMM, default 
            MPI communicator for parallel invocations

        radius_scale : double, default (2)
            Optional kernel radius scale. Defaults to 2

        ghost_layers : int, default (2)
            Optional factor for computing bounding boxes for cells.

        domain : DomainLimits, default (None)
            Optional limits for the domain

        lb_props : list
            optional list of properties required for load balancing

        """
        # number of arrays and a reference to the particle list
        self.narrays = len(particles)
        self.particles = particles

        # particle array wrappers
        self.pa_wrappers = [ParticleArrayWrapper(pa) for pa in particles]

        # particle array exchange instances
        self.pa_exchanges = [ParticleArrayExchange(pa, comm, lb_props) for pa in particles]

        # number of local/global/remote particles
        self.num_local = [pa.get_number_of_particles() for pa in particles]
        self.num_global = [0] * self.narrays
        self.num_remote = [0] * self.narrays

        # global indices used for load balancing
        self.cell_gid = UIntArray()

        # cell coordinate values used for load balancing
        self.cx = DoubleArray()
        self.cy = DoubleArray()
        self.cy = DoubleArray()

        # minimum and maximum arrays for MPI reduce operations. These
        # are used to find global bounds across processors.
        self.minx = np.zeros( shape=1, dtype=np.float64 )
        self.miny = np.zeros( shape=1, dtype=np.float64 )
        self.minz = np.zeros( shape=1, dtype=np.float64 )

        # global minimum values for x, y and z
        self.mx = 0.0; self.my = 0.0; self.mz = 0.0

        self.maxx = np.zeros( shape=1, dtype=np.float64 )
        self.maxy = np.zeros( shape=1, dtype=np.float64 )
        self.maxz = np.zeros( shape=1, dtype=np.float64 )
        self.maxh = np.zeros( shape=1, dtype=np.float64 )

        # global max values for x ,y, z & h
        self.Mx = 0.0; self.My = 0.0; self.Mz = 0.0; self.Mh = 0.0

        # from the init for ZoltanGeometricPartitioner, we have the
        # comm, rank and size setup
        self.in_parallel = True

        # MPI comm rank and size
        self.comm = comm
        self.rank = comm.Get_rank()
        self.size = comm.Get_size()
        
        if self.size == 1: self.in_parallel = False

        # The cells dictionary, radius scale for binning and ghost
        # layers for remote neighbors.
        self.cells = {}
        self.radius_scale = radius_scale
        self.ghost_layers = ghost_layers

        # setup cell import/export lists
        self._setup_arrays()

        # remove remote particles and create the local cell map
        self.remove_remote_particles()
        self.local_bin()

    cpdef compute_cell_size(self):
        """Compute the cell size for the binning.

        The cell size is chosen as the kernel radius scale times the
        maximum smoothing length in the local processor. For parallel
        runs, we would need to communicate the maximum 'h' on all
        processors to decide on the appropriate binning size.

        """
        # compute global bounds for the solution
        self._compute_bounds()
        cdef double hmax = self.Mh

        cell_size = self.radius_scale * hmax
        if cell_size < 1e-6:
            msg = """Cell size too small %g. Perhaps h = 0?
            Setting cell size to 1"""%(cell_size)
            print msg
            cell_size = 1.0
        self.cell_size = cell_size

    def update_cell_gids(self):
        """Update global indices for the cells dictionary.

        The objects to be partitioned in this class are the cells and
        we need to number them uniquely across processors. The
        numbering is done sequentially starting from the processor
        with rank 0 to the processor with rank size-1

        """
        # update the cell gids
        cdef PyZoltan pz = self.pz

        pz.num_local_objects = len(self.cells)
        pz._update_gid( self.cell_gid )

    def update_particle_gids(self):
        """Update individual particle global indices"""        
        for i in range(self.narrays):
            pa_exchange = self.pa_exchanges[i]
            pa_exchange.update_particle_gids()

            self.num_local[i] = pa_exchange.num_local
            self.num_global[i] = pa_exchange.num_global

    def update(self, initial=False):
        """Update the partition.

        This is the main entry point for the parallel manager. Given
        particles distributed across processors, we bin them, assign
        uniqe global indices for the cells and particles and
        subsequently perform the following steps:

        (a) Call a load balancing function to get import and export
            lists for the cell indices.

        for each particle array:

            (b) Create particle import/export lists using the cell
                import/export lists

            (c) Call ParticleArrayExchange's lb_exchange data with these particle
                import/export lists to effect the data movement for particles.

        (d) Update the local cell map after the data has been exchanged.

        now that we have the updated map, for each particle array:

            (e) Compute remote particle import/export lists from the cell map

            (f) Call ParticleArrayExchange's remote_exchange_data with these lists
                to effect the data movement.

        now that the data movement is done,

        (g) Update the local cell map to accomodate remote particles.

        Notes:
        ------

        Although not intended to be a 'parallel' NNPS, the
        ParallelManager can be used for this purpose. I don't think
        this is advisable in variable smoothing length simulations
        where we should be using a very coarse grained partitioning to
        ensure safe local computations.

        For two step integrators commonly employed in SPH and with a
        sufficient number of ghost layers for remote particles, we
        should call 'update' only at the end of a time step. The idea
        of multiple ghost layers is to ensure that local particles
        have a sufficiently large halo region around them.
        
        """
        # remove remote particles from a previous step
        self.remove_remote_particles()

        # update particle gids, bin particles and update cell gids
        self.update_particle_gids()
        self.local_bin()
        self.update_cell_gids()

        if self.in_parallel:

            # use Zoltan to get the cell import/export lists
            self.load_balance()

            # move the particle data one by one
            for i in range(self.narrays):

                # create the particle lists from the cell lists
                self.create_particle_lists(i)

                # move the particle data
                pa_exchange = self.pa_exchanges[i]
                pa_exchange.lb_exchange_data()

            # update the local cell map after data movement
            self.update_local_data()

            # compute remote particles and exchange data
            for i in range(self.narrays):
                self.compute_remote_particles(i)

                # move the remote particle data
                pa_exchange = self.pa_exchanges[i]
                pa_exchange.remote_exchange_data()

            # update the local cell map to accomodate remote particles
            self.update_remote_data()

            # align particles. I hate this but it must be done!
            for i in range(self.narrays):
                pa = self.particles[i]
                pa.align_particles()

    def remove_remote_particles(self):
        """Remove remote particles"""
        cdef int narrays = self.narrays
        cdef ParticleArrayExchange pa_exchange

        for i in range(narrays):
            pa_exchange = self.pa_exchanges[i]
            pa_exchange.remove_remote_particles()

            self.num_local[i] = pa_exchange.num_local
            self.num_remote[i] = pa_exchange.num_remote

    def local_bin(self):
        """Create the local cell map.

        Bin the particles by deleting any previous cells and
        re-computing the indexing structure. This corresponds to a
        local binning process that is called when each processor has
        a given list of particles to deal with.

        """
        cdef dict cells = self.cells
        cdef int num_particles
        cdef ParticleArray pa
        cdef UIntArray indices

        # clear the indices for the cells.
        self.cells.clear()

        # compute the cell size
        self.compute_cell_size()

        # # deal with ghosts
        # if self.is_periodic:
        #     # remove-ghost-particles
        #     self._remove_ghost_particles()

        #     # adjust local particles
        #     self._adjust_particles()

        #     # create new ghosts
        #     self._create_ghosts()

        # bin each particle array separately
        for i in range(self.narrays):
            num_particles = self.num_local[i]
            indices = arange_uint(num_particles)

            # bin the particles
            self._bin( i, indices )

    cdef _bin(self, int pa_index, UIntArray indices):
        """Bin a given particle array with indices.

        Parameters:
        -----------

        pa_index : int
            Index of the particle array corresponding to the particles list
        
        indices : UIntArray
            Subset of particles to bin

        """
        cdef pa_wrapper = self.pa_wrappers[ pa_index ]
        cdef DoubleArray x = pa_wrapper.x
        cdef DoubleArray y = pa_wrapper.y
        cdef DoubleArray z = pa_wrapper.z
        cdef UIntArray gid = pa_wrapper.gid

        cdef dict cells = self.cells
        cdef double cell_size = self.cell_size

        cdef UIntArray lindices, gindices
        cdef size_t num_particles, indexi, i

        cdef Cell cell
        cdef cIntPoint _cid
        cdef IntPoint cid = IntPoint()
        cdef cPoint pnt

        cdef int narrays = self.narrays
        cdef int layers = self.ghost_layers

        # now bin the particles
        num_particles = indices.length
        for indexi in range(num_particles):
            i = indices.data[indexi]

            pnt = cPoint_new( x.data[i], y.data[i], 0.0 )
            _cid = find_cell_id( pnt, cell_size )

            cid = IntPoint_from_cIntPoint(_cid)

            if not cells.has_key( cid ):
                cell = Cell(cid=cid, cell_size=cell_size,
                            narrays=self.narrays, layers=layers)

                #lindices = UIntArray()
                #gindices = UIntArray()
                #cell.set_indices( pa_index, lindices, gindices )
                cells[ cid ] = cell

            # add this particle to the list of indicies
            cell = cells[ cid ]

            lindices = cell.lindices[pa_index]
            gindices = cell.gindices[pa_index]

            lindices.append( <ZOLTAN_ID_TYPE> i )
            gindices.append( gid.data[i] )

    def update_local_data(self):
        """Update the cell map after load balance.
        
        After the load balancing step, each processor has a new set of
        local particles which need to be indexed. This new cell
        structure is then used to compute remote particles.

        """
        cdef ParticleArrayExchange pa_exchange
        cdef int num_particles, i
        cdef UIntArray indices

        # clear the local cells dict
        self.cells.clear()

        for i in range(self.narrays):
            pa_exchange = self.pa_exchanges[i]
            num_particles = pa_exchange.num_local

            # set the number of local and global particles
            self.num_local[i] = pa_exchange.num_local
            self.num_global[i] = pa_exchange.num_global

            # bin the particles
            indices = arange_uint( num_particles )
            self._bin(i, indices)

    def update_remote_data(self):
        """Update the cell structure after sharing remote particles.

        After exchanging remote particles, we need to index the new
        remote particles for a possible neighbor query.

        """
        cdef int narrays = self.narrays
        cdef int num_local, num_remote, i
        cdef ParticleArrayExchange pa_exchange
        cdef UIntArray indices

        for i in range(narrays):
            pa_exchange = self.pa_exchanges[i]

            # get the number of local and remote particles
            num_local = pa_exchange.num_local
            num_remote = pa_exchange.num_remote

            # update the number of local/remote particles
            self.num_local[i] = num_local
            self.num_remote[i] = num_remote

            indices = arange_uint( num_local, num_local + num_remote )
            self._bin( i, indices )

    def load_balance(self):
        raise NotImplementedError("ParallelManager::load_balance")

    def create_particle_lists(self, pa_index):
        raise NotImplementedError("ParallelManager::create_particle_lists")

    def compute_remote_particles(self, pa_index):
        raise NotImplementedError("ParallelManager::compute_remote_particles")

    #######################################################################
    # Private interface
    #######################################################################
    def set_data(self):
        """Compute the user defined data for use with Zoltan"""
        raise NotImplementedError("ZoltanParallelManager::_set_data should not be called!")
    
    def _setup_arrays(self):
        # Import/Export lists for cells
        self.exportCellGlobalids = UIntArray()
        self.exportCellLocalids = UIntArray()
        self.exportCellProcs = IntArray()

        self.importCellGlobalids = UIntArray()
        self.importCellLocalids = UIntArray()
        self.importCellProcs = IntArray()

        self.numCellImport = 0
        self.numCellExport = 0

    cdef _compute_bounds(self):
        """Compute the domain bounds for indexing."""

        cdef double mx, my, mz
        cdef double Mx, My, Mz, Mh

        cdef list pa_wrappers = self.pa_wrappers
        cdef ParticleArrayWrapper pa
        cdef DoubleArray x, y, z, h

        # set some high and low values
        cdef double high = -1e20, low = 1e20
        mx = low; my = low; mz = low
        Mx = high; My = high; Mz = high; Mh = high

        # find the local min and max for all arrays on this proc
        for pa in pa_wrappers:
            x = pa.x; y = pa.y; z = pa.z; h = pa.h
            if x.length > 0:
                x.update_min_max(); y.update_min_max()
                z.update_min_max(); h.update_min_max()

                if x.minimum < mx: mx = x.minimum
                if x.maximum > Mx: Mx = x.maximum
            
                if y.minimum < my: my = y.minimum
                if y.maximum > My: My = y.maximum
            
                if z.minimum < mz: mz = z.minimum
                if z.maximum > Mz: Mz = z.maximum
            
                if h.maximum > Mh: Mh = h.maximum

        self.minx[0] = mx; self.miny[0] = my; self.minz[0] = mz
        self.maxx[0] = Mx; self.maxy[0] = My; self.maxz[0] = Mz
        self.maxh[0] = Mh

        # now compute global min and max if in parallel
        comm = self.comm
        if self.in_parallel:

            # revc buffers for all reduce
            _minx = np.zeros_like(self.minx)
            _miny = np.zeros_like(self.miny)
            _minz = np.zeros_like(self.minz)

            _maxx = np.zeros_like(self.maxx)
            _maxy = np.zeros_like(self.maxy)
            _maxz = np.zeros_like(self.maxz)
            _maxh = np.zeros_like(self.maxh)

            # global reduction for minimum values
            comm.Allreduce(sendbuf=self.minx, recvbuf=_minx, op=mpi.MIN)
            comm.Allreduce(sendbuf=self.miny, recvbuf=_miny, op=mpi.MIN)
            comm.Allreduce(sendbuf=self.minz, recvbuf=_minz, op=mpi.MIN)

            # global reduction for maximum values
            comm.Allreduce(sendbuf=self.maxx, recvbuf=_maxx, op=mpi.MAX)
            comm.Allreduce(sendbuf=self.maxy, recvbuf=_maxy, op=mpi.MAX)
            comm.Allreduce(sendbuf=self.maxz, recvbuf=_maxz, op=mpi.MAX)
            comm.Allreduce(sendbuf=self.maxh, recvbuf=_maxh, op=mpi.MAX)
            
        self.mx = _minx[0]; self.my = _miny[0]; self.mz = _minz[0]
        self.Mx = _maxx[0]; self.My = _maxy[0]; self.Mz = _maxz[0]
        self.Mh = _maxh[0]

    ######################################################################
    # Neighbor location routines
    ######################################################################
    cpdef get_nearest_particles(self, int src_index, int dst_index,
                                size_t i, UIntArray nbrs):
        """Utility function to get near-neighbors for a particle.

        Parameters:
        -----------

        src_index : int
            Index of the source particle array in the particles list

        dst_index : int
            Index of the destination particle array in the particles list

        i : int (input)
            Particle for which neighbors are sought.

        nbrs : UIntArray (output)
            Neighbors for the requested particle are stored here.

        """
        cdef dict cells = self.cells
        cdef Cell cell

        cdef ParticleArrayWrapper src = self.pa_wrappers[ src_index ]
        cdef ParticleArrayWrapper dst = self.pa_wrappers[ dst_index ]

        # Source data arrays
        cdef DoubleArray s_x = src.x
        cdef DoubleArray s_y = src.y
        cdef DoubleArray s_h = src.h

        # Destination particle arrays
        cdef DoubleArray d_x = dst.x
        cdef DoubleArray d_y = dst.y
        cdef DoubleArray d_h = dst.h

        cdef double radius_scale = self.radius_scale
        cdef double cell_size = self.cell_size
        cdef UIntArray lindices
        cdef size_t indexj
        cdef ZOLTAN_ID_TYPE j

        cdef cPoint xi = cPoint_new(d_x.data[i], d_y.data[i], 0.0)
        cdef cIntPoint _cid = find_cell_id( xi, cell_size )
        cdef IntPoint cid = IntPoint_from_cIntPoint( _cid )
        cdef IntPoint cellid = IntPoint(0, 0, 0)

        cdef cPoint xj
        cdef double xij

        cdef double hi, hj
        hi = radius_scale * d_h.data[i]

        cdef int nnbrs = 0

        cdef int ix, iy
        for ix in [cid.data.x -1, cid.data.x, cid.data.x + 1]:
            for iy in [cid.data.y - 1, cid.data.y, cid.data.y + 1]:
                cellid.data.x = ix; cellid.data.y = iy

                if cells.has_key( cellid ):
                    cell = cells[ cellid ]
                    lindices = cell.lindices[src_index]
                    for indexj in range( lindices.length ):
                        j = lindices.data[indexj]

                        xj = cPoint_new( s_x.data[j], s_y.data[j], 0.0 )
                        xij = cPoint_distance( xi, xj )

                        hj = radius_scale * s_h.data[j]

                        if ( (xij < hi) or (xij < hj) ):
                            if nnbrs == nbrs.length:
                                nbrs.resize( nbrs.length + 50 )
                                print """Neighbor search :: Extending the neighbor list to %d"""%(nbrs.length)

                            nbrs.data[ nnbrs ] = j
                            nnbrs = nnbrs + 1

        # update the _length for nbrs to indicate the number of neighbors
        nbrs._length = nnbrs            

cdef class ZoltanParallelManager(ParallelManager):
    """Base class for Zoltan enabled parallel cell managers.

    To partition a list of arrays, we do an NNPS like box sort on all
    arrays to create a global spatial indexing structure. The cells
    are then used as 'objects' to be partitioned by Zoltan. The cells
    dictionary (cell-map) need not be unique across processors. We are
    responsible for assignning unique global ids for the cells.

    The Zoltan generated (cell) import/export lists are then used to
    construct particle import/export lists which are used to perform
    the data movement of the particles. A ParticleArrayExchange object
    (lb_exchange_data and remote_exchange_data) is used for each
    particle array in turn to effect this movement.

    """
    def __init__(self, int dim, list particles, object comm,
                 double radius_scale=2.0,
                 int ghost_layers=2, domain=None,
                 lb_props=None, str lb_method='RCB'):
        """Constructor.

        Parameters:
        -----------

        dim : int
            Dimension

        particles : list
            list of particle arrays to be managed.

        comm : mpi4py.MPI.COMM, default 
            MPI communicator for parallel invocations

        radius_scale : double, default (2)
            Optional kernel radius scale. Defaults to 2

        ghost_layers : int, default (2)
            Optional factor for computing bounding boxes for cells.

        domain : DomainLimits, default (None)
            Optional limits for the domain

        lb_props : list
            optional list of properties required for load balancing

        lb_method : string
            optional initial load balancing method

        """
        super(ZoltanParallelManager, self).__init__(
            dim, particles, comm, radius_scale, ghost_layers, lb_props)

        # Initialize the base PyZoltan class. 
        self.pz = PyZoltan(comm)

    def create_particle_lists(self, int pa_index):
        """Create particle export/import lists

        For the cell based partitioner, Zoltan generated import and
        export lists apply to the cells. From this data, we can
        generate local export indices for the particles which must
        then be inverted to get the requisite import lists.

        We first construct the particle export lists in local arrays
        using the information from Zoltan_LB_Balance and subsequently
        call Zoltan_Invert_Lists to get the import lists. These arrays
        are then copied to the ParticleArrayExchange import/export
        lists.

        """
        # PyZoltan reference
        cdef PyZoltan pz = self.pz
        
        # these are the Zoltan generated lists that correspond to cells
        cdef UIntArray exportCellLocalids = self.exportCellLocalids
        cdef UIntArray exportCellGlobalids = self.exportCellGlobalids
        cdef IntArray exportCellProcs = self.exportCellProcs
        cdef int numCellExport = self.numCellExport

        # the local cell map and cellids
        cdef dict cell_map = self.cells
        cdef list cellids = cell_map.keys()
        cdef list cells = cell_map.values()
        cdef IntPoint cellid
        cdef Cell cell

        # temp buffers to create the particle lists. these will be
        # copied over to the main lists
        cdef UIntArray _exportLocalids = UIntArray()
        cdef UIntArray _exportGlobalids = UIntArray()
        cdef IntArray _exportProcs = IntArray()
        cdef int _numExport = 0

        cdef int indexi, i, j, export_proc, nindices
        cdef UIntArray lindices, gindices
        cdef int ierr

        cdef ParticleArrayExchange pa_exchange = self.pa_exchanges[pa_index]

        # iterate over the Zoltan generated export lists
        for indexi in range(numCellExport):
            i = exportCellLocalids[indexi]             # local index for the cell to export
            cell = cells[ i ]                      # local cell to export
            export_proc = exportCellProcs.data[indexi] # processor to export cell to
            lindices = cell.lindices[pa_index]               # local particle  indices in cell
            gindices = cell.gindices[pa_index]               # global particle indices in cell
            nindices = lindices.length

            for j in range( nindices ):
                _exportLocalids.append( lindices.data[j] )
                _exportGlobalids.append( gindices.data[j] )
                _exportProcs.append( export_proc )

                _numExport = _numExport + 1

            # remove the cell from the local cell map
            cellid = cellids[ i ]
            cell_map.pop( cellid )

        # resize the export lists and copy
        pz.numExport =  _numExport
        pz.exportLocalids.resize( _numExport )
        pz.exportGlobalids.resize( _numExport )
        pz.exportProcs.resize( _numExport )

        pz.exportLocalids.copy_subset( _exportLocalids )
        pz.exportGlobalids.copy_subset( _exportGlobalids )
        pz.exportProcs.copy_subset( _exportProcs )

        # Given the export particle indices, we invert the lists to
        # get the import lists from remote processors...
        pz.Zoltan_Invert_Lists()

        # now copy over to the particle lists
        pa_exchange.numParticleExport = pz.numExport
        pa_exchange.exportParticleGlobalids.resize( pz.numExport )
        pa_exchange.exportParticleGlobalids.copy_subset( pz.exportGlobalids )

        pa_exchange.exportParticleLocalids.resize( pz.numExport )
        pa_exchange.exportParticleLocalids.copy_subset( pz.exportLocalids )

        pa_exchange.exportParticleProcs.resize( pz.numExport )
        pa_exchange.exportParticleProcs.copy_subset( pz.exportProcs )

        pa_exchange.numParticleImport = pz.numImport
        pa_exchange.importParticleGlobalids.resize( pz.numImport )
        pa_exchange.importParticleGlobalids.copy_subset( pz.importGlobalids )

        pa_exchange.importParticleLocalids.resize( pz.numImport )
        pa_exchange.importParticleLocalids.copy_subset( pz.importLocalids )

        pa_exchange.importParticleProcs.resize( pz.numImport )
        pa_exchange.importParticleProcs.copy_subset( pz.importProcs )

    def compute_remote_particles(self, int pa_index):
        """Compute remote particles.

        Particles to be exported are determined by flagging individual
        cells and where they need to be shared to meet neighbor
        requirements.
        
        """
        cdef PyZoltan pz = self.pz
        cdef Zoltan_Struct* zz = pz._zstruct.zz
        cdef UIntArray exportGlobalids, exportLocalids
        cdef IntArray exportProcs

        cdef Cell cell
        cdef cPoint boxmin, boxmax

        cdef object comm = self.comm
        cdef int rank = self.rank
        cdef int size = self.size
        
        cdef dict cells = self.cells
        cdef IntPoint cid
        cdef UIntArray lindices, gindices

        cdef np.ndarray nbrprocs
        cdef np.ndarray[ndim=1, dtype=np.int32_t] procs, parts
        
        cdef int nbrproc, num_particles
        cdef ZOLTAN_ID_TYPE i

        cdef int *_procs, *_parts
        cdef int numprocs = 0
        cdef int numparts = 0

        cdef ParticleArrayExchange pa_exchange = self.pa_exchanges[pa_index]

        # reset the Zoltan lists
        pz.reset_Zoltan_lists()
        exportGlobalids = pz.exportGlobalids
        exportLocalids = pz.exportLocalids
        exportProcs = pz.exportProcs

        # initialize the procs and parts
        procs = pz.procs
        parts = pz.parts
        
        for cid in cells:
            cell = cells[ cid ]

            # reset the procs and parts to -1
            procs[:] = -1; parts[:] = -1

            _procs = <int*>procs.data
            _parts = <int*>parts.data

            # get the bounding box for this cell
            boxmin = cell.boxmin; boxmax = cell.boxmax

            czoltan.Zoltan_LB_Box_PP_Assign(
                zz,
                boxmin.x, boxmin.y, boxmin.z,
                boxmax.x, boxmax.y, boxmax.z,
                _procs, &numprocs,
                _parts, &numparts
                )                

            # array of neighboring processors
            nbrprocs = procs[np.where( (procs != -1) * (procs != rank) )[0]]

            if nbrprocs.size > 0:
                cell.is_boundary = True

                lindices = cell.lindices[pa_index]
                gindices = cell.gindices[pa_index]
                cell.nbrprocs.resize( nbrprocs.size )
                cell.nbrprocs.set_data( nbrprocs )
                
                num_particles = lindices.length
                for nbrproc in nbrprocs:
                    for indexi in range( num_particles ):
                        i = lindices.data[indexi]

                        exportGlobalids.append( gindices.data[indexi] )
                        exportLocalids.append( i )
                        exportProcs.append( nbrproc )

        # set the numImport and numExport
        pz.numImport = 0
        pz.numExport = exportProcs.length

        # Invert the lists...
        pz.Zoltan_Invert_Lists()

        # copy the lists to the particle lists
        pa_exchange.numParticleExport = pz.numExport
        pa_exchange.numParticleImport = pz.numImport

        pa_exchange.exportParticleGlobalids.resize( pz.numExport )
        pa_exchange.exportParticleGlobalids.copy_subset( pz.exportGlobalids )

        pa_exchange.exportParticleLocalids.resize( pz.numExport )
        pa_exchange.exportParticleLocalids.copy_subset( pz.exportLocalids )
        
        pa_exchange.exportParticleProcs.resize( pz.numExport )
        pa_exchange.exportParticleProcs.copy_subset( pz.exportProcs )

        pa_exchange.importParticleGlobalids.resize( pz.numImport )
        pa_exchange.importParticleGlobalids.copy_subset( pz.importGlobalids )

        pa_exchange.importParticleLocalids.resize( pz.numImport )
        pa_exchange.importParticleLocalids.copy_subset( pz.importLocalids )

        pa_exchange.importParticleProcs.resize( pz.numImport )
        pa_exchange.importParticleProcs.copy_subset( pz.importProcs )        

    def load_balance(self):
        """Use Zoltan to generate import/export lists for the cells.

        For the Zoltan interface, we require to populate a user
        defined struct with appropriate data for Zoltan to deal
        with. For the geometric based partitioners for example, we
        require the unique cell global indices and arrays for the cell
        centroid coordinates. Computation of this data must be done
        prior to calling 'pz.Zoltan_LB_Balance' through a call to
        'set_data'

        """
        cdef PyZoltan pz = self.pz

        # set the data which will be used by the Zoltan wrapper
        self.set_data()

        # call Zoltan to get the cell import/export lists
        pz.Zoltan_LB_Balance()

        # copy the Zoltan export lists to the cell lists
        self.numCellExport = pz.numExport
        self.exportCellGlobalids.resize( pz.numExport )
        self.exportCellGlobalids.copy_subset( pz.exportGlobalids )

        self.exportCellLocalids.resize( pz.numExport )
        self.exportCellLocalids.copy_subset( pz.exportLocalids )

        self.exportCellProcs.resize( pz.numExport )
        self.exportCellProcs.copy_subset( pz.exportProcs )

        # copy the Zoltan import lists to the cell lists
        self.numCellImport = pz.numImport
        self.importCellGlobalids.resize( pz.numImport )
        self.importCellGlobalids.copy_subset( pz.importGlobalids )

        self.importCellLocalids.resize( pz.numImport )
        self.importCellLocalids.copy_subset( pz.importLocalids )

        self.importCellProcs.resize( pz.numImport )
        self.importCellProcs.copy_subset( pz.importProcs )

cdef class ZoltanParallelManagerGeometric(ZoltanParallelManager):
    """Zoltan enabled parallel manager for use with geometric load balancing.

    Use this class for the Zoltan RCB, RIB and HSFC load balancing
    algorithms.

    """
    def __init__(self, int dim, list particles, object comm,
                 double radius_scale=2.0,
                 int ghost_layers=2, domain=None,
                 lb_props=None, str lb_method='RCB'):

        # initialize the base class
        super(ZoltanParallelManagerGeometric, self).__init__(
            dim, particles, comm, radius_scale, ghost_layers, domain,
            lb_props, lb_method)

        # concrete implementation of a PyZoltan class
        self.pz = ZoltanGeometricPartitioner(
            dim, self.comm, self.cx, self.cy, self.cz, self.cell_gid)
                                                
    def set_data(self):
        """Set the user defined particle data structure for Zoltan.

        For the geometric based partitioners, Zoltan requires as input
        the number of local/global objects, unique global indices for
        the local objects and coordinate values for the local
        objects.

        """

        cdef ZoltanGeometricPartitioner pz = self.pz
        
        cdef dict cell_map = self.cells
        cdef list cells = cell_map.values()

        cdef int num_local_objects = pz.num_local_objects
        cdef int num_global_objects = pz.num_global_objects

        cdef DoubleArray x = self.cx
        cdef DoubleArray y = self.cy

        cdef int i
        cdef Cell cell
        cdef cPoint centroid

        # resize the coordinate arrays
        x.resize( num_local_objects )
        y.resize( num_local_objects )

        # populate the arrays
        for i in range( num_local_objects ):
            cell = cells[ i ]
            centroid = cell.centroid

            x.data[i] = centroid.x
            y.data[i] = centroid.y