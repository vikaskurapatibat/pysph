# numpy import
import numpy as np
cimport numpy as np

# malloc and friends
from libc.stdlib cimport malloc, free

# cpython
from cpython.dict cimport PyDict_Clear, PyDict_Contains, PyDict_GetItem
from cpython.list cimport PyList_GetItem

cdef extern from 'math.h':
    int abs(int)
    double ceil(double)
    double floor(double)
    double fabs(double)

cdef extern from 'limits.h':
    cdef int INT_MAX

# ZOLTAN ID TYPE AND PTR
ctypedef unsigned int ZOLTAN_ID_TYPE
ctypedef unsigned int* ZOLTAN_ID_PTR

# Particle Tag information
from utils import ParticleTAGS

cdef int Local = ParticleTAGS.Local
cdef int Remote = ParticleTAGS.Remote
cdef int Ghost = ParticleTAGS.Ghost

cdef inline double fmin(double x, double y):
    if x < y:
        return x
    else: return y

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

#################################################################
# NNPS extension classes
#################################################################
cdef class NNPSParticleArrayWrapper:
    def __init__(self, ParticleArray pa):
        self.pa = pa
        self.name = pa.name

        self.x = pa.get_carray('x')
        self.y = pa.get_carray('y')
        self.z = pa.get_carray('z')
        self.h = pa.get_carray('h')

        self.np = pa.get_number_of_particles()
        
cdef class DomainLimits:
    """This class determines the limits of the solution domain.

    We expect all simulations to have well defined domain limits
    beyond which we are either not interested or the solution is
    invalid to begin with. Thus, if a particle leaves the domain,
    the simulation should be considered invalid.

    The initial domain limits could be given explicitly or asked to be
    computed from the particle arrays. The domain could be periodic.

    """
    def __init__(self, int dim=1, double xmin=-1000, double xmax=1000, double ymin=0,
                 double ymax=0, double zmin=0, double zmax=0, is_periodic=False):
        """Constructor"""
        self._check_limits(dim, xmin, xmax, ymin, ymax, zmin, zmax)
        
        self.xmin = xmin; self.xmax = xmax
        self.ymin = ymin; self.ymax = ymax
        self.zmin = zmin; self.zmax = zmax

        # Indicates if the domain is periodic
        self.is_periodic = is_periodic

        # get the translates in each coordinate direction
        self.xtranslate = xmax - xmin
        self.ytranslate = ymax - ymin
        self.ztranslate = zmax - zmin

        # store the dimension
        self.dim = dim

    def _check_limits(self, dim, xmin, xmax, ymin, ymax, zmin, zmax):
        """Sanity check on the limits"""
        if ( (xmax < xmin) or (ymax < ymin) or (zmax < zmin) ):
            raise ValueError("Invalid domain limits!")

cdef class Cell:
    """Basic indexing structure.

    For a spatial indexing based on the box-sort algorithm, this class
    defines the spatial data structure used to hold particle indices
    (local and global) that are within this cell. 

    """
    def __init__(self, IntPoint cid, double cell_size, int narrays,
                 int layers=2):
        """Constructor

        Parameters:
        -----------

        cid : IntPoint
            Spatial index (unflattened) for the cell

        cell_size : double
            Spatial extent of the cell in each dimension

        narrays : int
            Number of arrays being binned

        layers : int
            Factor to compute the bounding box        

        """
        self._cid = cIntPoint_new(cid.x, cid.y, cid.z)
        self.cell_size = cell_size

        self.narrays = narrays

        self.lindices = [UIntArray() for i in range(narrays)]
        self.gindices = [UIntArray() for i in range(narrays)]
        
        self.nparticles = [lindices.length for lindices in self.lindices]
        self.is_boundary = False

        # compute the centroid for the cell
        self.centroid = _get_centroid(cell_size, cid.data)

        # cell bounding box
        self.layers = layers
        self._compute_bounding_box(cell_size, layers)

        # list of neighboring processors
        self.nbrprocs = IntArray(0)

    cpdef set_indices(self, int index, UIntArray lindices, UIntArray gindices):
        """Set the global and local indices for the cell"""
        self.lindices[index] = lindices
        self.gindices[index] = gindices
        self.nparticles[index] = lindices.length

    def get_centroid(self, Point pnt):
        """Utility function to get the centroid of the cell.

        Parameters:
        -----------

        pnt : Point (input/output)
            The centroid is cmoputed and stored in this object.

        The centroid is defined as the origin plus half the cell size
        in each dimension.
        
        """
        cdef cPoint centroid = self.centroid
        pnt.data = centroid

    def get_bounding_box(self, Point boxmin, Point boxmax, int layers = 1,
                         cell_size=None):
        """Compute the bounding box for the cell.

        Parameters:
        ------------

        boxmin : Point (output)
            The bounding box min coordinates are stored here

        boxmax : Point (output)
            The bounding box max coordinates are stored here

        layers : int (input) default (1)
            Number of offset layers to define the bounding box

        cell_size : double (input) default (None)
            Optional cell size to use to compute the bounding box.
            If not provided, the cell's size will be used.        

        """
        if cell_size is None:
            cell_size = self.cell_size

        self._compute_bounding_box(cell_size, layers)
        boxmin.data = self.boxmin
        boxmax.data = self.boxmax

    cdef _compute_bounding_box(self, double cell_size,
                               int layers):
        self.layers = layers
        cdef cPoint centroid = self.centroid
        cdef cPoint boxmin = cPoint_new(0., 0., 0.)
        cdef cPoint boxmax = cPoint_new(0., 0., 0.)

        boxmin.x = centroid.x - (layers+0.5) * cell_size
        boxmax.x = centroid.x + (layers+0.5) * cell_size

        boxmin.y = centroid.y - (layers+0.5) * cell_size
        boxmax.y = centroid.y + (layers+0.5) * cell_size

        boxmin.z = 0.
        boxmax.z = 0.

        self.boxmin = boxmin
        self.boxmax = boxmax

cdef class NNPS:
    """Nearest neighbor query class using the box-sort algorithm.

    NNPS bins all local particles using the box sort algorithm in
    Cells. The cells are stored in a dictionary 'cells' which is keyed
    on the spatial index (IntPoint) of the cell.

    """
    def __init__(self, int dim, list particles, double radius_scale=2.0,
                 int ghost_layers=1, domain=None):
        """Constructor for NNPS

        Parameters:
        -----------

        dim : int
            Dimension (Not sure if this is really needed)

        particles : list
            The list of particles we are working on

        radius_scale : double, default (2)
            Optional kernel radius scale. Defaults to 2

        domain : DomainLimits, default (None)
            Optional limits for the domain            

        """
        # store the list of particles and number of arrays
        self.particles = particles
        self.narrays = len( particles )

        # create the particle array wrappers
        self.pa_wrappers = [NNPSParticleArrayWrapper(pa) for pa in particles]

        # radius scale and problem dimensionality
        self.radius_scale = radius_scale
        self.dim = dim

        self.domain = domain
        if domain is None:
            self.domain = DomainLimits(dim)

        # initialize the cells dict
        self.cells = {}

        # compute the intial box sort
        self.update()

    cpdef update(self):
        """Update the local data after a parallel update.

        We want the NNPS to be independent of the ParallelManager
        which is solely responsible for distributing particles across
        available processors. We assume therefore that after a
        parallel update, each processor has all the local particle
        information it needs.

        """
        cdef dict cells = self.cells
        cdef int i, num_particles
        cdef ParticleArray pa
        cdef UIntArray indices

        # clear the cells dict
        PyDict_Clear( cells )

        # compute the cell size
        self._compute_cell_size()

        # indices on which to bin
        for i in range(self.narrays):
            pa = self.particles[i]
            num_particles = pa.get_number_of_particles()
            indices = arange_uint(num_particles)

            # bin the particles
            self._bin( pa_index=i, indices=indices )

    cdef _bin(self, int pa_index, UIntArray indices):
        """Bin a given particle array with indices.

        Parameters:
        -----------

        pa_index : int
            Index of the particle array corresponding to the particles list
        
        indices : UIntArray
            Subset of particles to bin

        """
        cdef NNPSParticleArrayWrapper pa_wrapper = self.pa_wrappers[ pa_index ]
        cdef DoubleArray x = pa_wrapper.x
        cdef DoubleArray y = pa_wrapper.y

        cdef dict cells = self.cells
        cdef double cell_size = self.cell_size

        cdef UIntArray lindices, gindices
        cdef size_t num_particles, indexi, i

        cdef cIntPoint _cid
        cdef IntPoint cid

        cdef Cell cell
        cdef int ierr, narrays = self.narrays

        # now bin the particles
        num_particles = indices.length
        for indexi in range(num_particles):
            i = indices.data[indexi]

            pnt = cPoint_new( x.data[i], y.data[i], 0.0 )
            _cid = find_cell_id( pnt, cell_size )

            cid = IntPoint_from_cIntPoint(_cid)

            ierr = PyDict_Contains(cells, cid)
            if ierr == 0:
                cell = Cell(cid, cell_size, narrays)
                cells[ cid ] = cell

            # add this particle to the list of indicies
            cell = <Cell>PyDict_GetItem( cells, cid )
            lindices = <UIntArray>PyList_GetItem( cell.lindices, pa_index )

            lindices.append( <ZOLTAN_ID_TYPE> i )
            #gindices.append( gid.data[i] )

    cdef _compute_cell_size(self):
        """Compute the cell size for the binning.
        
        The cell size is chosen as the kernel radius scale times the
        maximum smoothing length in the local processor. For parallel
        runs, we would need to communicate the maximum 'h' on all
        processors to decide on the appropriate binning size.

        """        
        cdef list pa_wrappers = self.pa_wrappers
        cdef NNPSParticleArrayWrapper pa_wrapper
        cdef DoubleArray h
        cdef double cell_size
        cdef double _hmax, hmax = -1.0

        for pa_wrapper in pa_wrappers:
            h = pa_wrapper.h
            h.update_min_max()

            _hmax = h.maximum
            if _hmax > hmax:
                hmax = _hmax

        cell_size = self.radius_scale * hmax

        if cell_size < 1e-6:
            msg = """Cell size too small %g. Perhaps h = 0?
            Setting cell size to 1"""%(cell_size)
            print msg
            cell_size = 1.0

        self.cell_size = cell_size
        
    ######################################################################
    # Neighbor location routines
    ######################################################################            
    cpdef get_nearest_particles(self, int src_index, int dst_index,
                                size_t d_idx, UIntArray nbrs):
        """Utility function to get near-neighbors for a particle.

        Parameters:
        -----------

        src_index : int
            Index of the source particle array in the particles list

        dst_index : int
            Index of the destination particle array in the particles list

        d_idx : int (input)
            Destination particle for which neighbors are sought.

        nbrs : UIntArray (output)
            Neighbors for the requested particle are stored here.

        """
        cdef dict cells = self.cells
        cdef Cell cell

        cdef NNPSParticleArrayWrapper src = self.pa_wrappers[ src_index ]
        cdef NNPSParticleArrayWrapper dst = self.pa_wrappers[ dst_index ]

        # Source data arrays
        cdef DoubleArray s_x = src.x
        cdef DoubleArray s_y = src.y
        cdef DoubleArray s_z = src.z
        cdef DoubleArray s_h = src.h

        # Destination particle arrays
        cdef DoubleArray d_x = dst.x
        cdef DoubleArray d_y = dst.y
        cdef DoubleArray d_z = dst.z
        cdef DoubleArray d_h = dst.h

        cdef double radius_scale = self.radius_scale
        cdef double cell_size = self.cell_size
        cdef UIntArray lindices
        cdef size_t indexj
        cdef ZOLTAN_ID_TYPE j

        cdef cPoint xi = cPoint_new(d_x.data[d_idx], d_y.data[d_idx], d_z.data[d_idx])
        cdef cIntPoint _cid = find_cell_id( xi, cell_size )
        cdef IntPoint cid = IntPoint_from_cIntPoint( _cid )
        cdef IntPoint cellid = IntPoint(0, 0, 0)

        cdef cPoint xj
        cdef double xij

        cdef double hi, hj
        hi = radius_scale * d_h.data[d_idx]

        cdef int ierr, nnbrs = 0

        cdef int ix, iy
        for ix in [cid.data.x -1, cid.data.x, cid.data.x + 1]:
            for iy in [cid.data.y - 1, cid.data.y, cid.data.y + 1]:
                cellid.data.x = ix; cellid.data.y = iy

                ierr = PyDict_Contains( cells, cellid )
                if ierr == 1:

                    cell = <Cell>PyDict_GetItem( cells, cellid )
                    lindices = <UIntArray>PyList_GetItem( cell.lindices, src_index )

                    for indexj in range( lindices.length ):
                        j = lindices.data[indexj]

                        xj = cPoint_new( s_x.data[j], s_y.data[j], s_z.data[j] )
                        xij = cPoint_distance( xi, xj )

                        hj = radius_scale * s_h.data[j]

                        if ( (xij < hi) or (xij < hj) ):
                            if nnbrs == nbrs.length:
                                nbrs.resize( nbrs.length + 50 )
                                print """NNPS:: Extending the neighbor list to %d"""%(nbrs.length)

                            nbrs.data[ nnbrs ] = j
                            nnbrs = nnbrs + 1

        # update the _length for nbrs to indicate the number of neighbors
        nbrs._length = nnbrs

    cpdef brute_force_neighbors(self, int src_index, int dst_index,
                                size_t d_idx, UIntArray nbrs):
        cdef NNPSParticleArrayWrapper src = self.pa_wrappers[src_index]
        cdef NNPSParticleArrayWrapper dst = self.pa_wrappers[dst_index]
        
        cdef DoubleArray s_x = src.x
        cdef DoubleArray s_y = src.y
        cdef DoubleArray s_z = src.z
        cdef DoubleArray s_h = src.h

        cdef DoubleArray d_x = dst.x
        cdef DoubleArray d_y = dst.y
        cdef DoubleArray d_z = dst.z
        cdef DoubleArray d_h = dst.h

        cdef double cell_size = self.cell_size
        cdef double radius_scale = self.radius_scale

        cdef size_t num_particles, j

        num_particles = d_x.length
        cdef double xi = d_x.data[d_idx]
        cdef double yi = d_y.data[d_idx]
        cdef double zi = d_z.data[d_idx]

        cdef double hi = d_h.data[d_idx] * radius_scale
        cdef double xj, yj, hj, hj2

        cdef double xij2
        cdef double hi2 = hi*hi

        # reset the neighbors
        nbrs.reset()

        for j in range(num_particles):
            xj = s_x.data[j]; yj = s_y.data[j]; zj = s_z.data[j];
            hj = s_h.data[j]

            xij2 = (xi - xj)*(xi - xj) + \
                   (yi - yj)*(yi - yj) + \
                   (zi - zj)*(zi - zj)

            hj2 = hj*hj
            if ( (xij2 < hi2) or (xij2 < hj2) ):
                nbrs.append( <ZOLTAN_ID_TYPE> j )

        return nbrs