#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* We have to steal a bunch of code from B.xs so that we can generate
   B objects from ops. Disturbing but true. */

#ifdef PERL_OBJECT
#undef PL_opargs
#define PL_opargs (get_opargs())
#endif

typedef enum { OPc_NULL, OPc_BASEOP, OPc_UNOP, OPc_BINOP, OPc_LOGOP, OPc_LISTOP, 
    OPc_PMOP, OPc_SVOP, OPc_PADOP, OPc_PVOP, OPc_CVOP, OPc_LOOP, OPc_COP } opclass;

static char *opclassnames[] = {
    "B::NULL", "B::OP", "B::UNOP", "B::BINOP", "B::LOGOP", "B::LISTOP", 
    "B::PMOP", "B::SVOP", "B::PADOP", "B::PVOP", "B::CVOP", "B::LOOP", "B::COP"
};

typedef OP *B__OP;

static opclass
cc_opclass(pTHX_ OP *o)
{
    if (!o)
        return OPc_NULL;

    if (o->op_type == 0)
        return (o->op_flags & OPf_KIDS) ? OPc_UNOP : OPc_BASEOP;

    if (o->op_type == OP_SASSIGN)
        return ((o->op_private & OPpASSIGN_BACKWARDS) ? OPc_UNOP : OPc_BINOP);

#ifdef USE_ITHREADS
    if (o->op_type == OP_GV || o->op_type == OP_GVSV || o->op_type == OP_AELEMFAST)
        return OPc_PADOP;
#endif

    switch (PL_opargs[o->op_type] & OA_CLASS_MASK) {
    case OA_BASEOP: return OPc_BASEOP;
    case OA_UNOP:   return OPc_UNOP;
    case OA_BINOP:  return OPc_BINOP;
    case OA_LOGOP:  return OPc_LOGOP;
    case OA_LISTOP: return OPc_LISTOP; 
    case OA_PMOP:   return OPc_PMOP;
    case OA_SVOP:   return OPc_SVOP;
    case OA_PADOP:  return OPc_PADOP;
    case OA_PVOP_OR_SVOP:
        return (o->op_private & (OPpTRANS_TO_UTF|OPpTRANS_FROM_UTF))
                ? OPc_SVOP : OPc_PVOP;
    case OA_LOOP:   return OPc_LOOP;
    case OA_COP:    return OPc_COP;
    case OA_BASEOP_OR_UNOP:
        return (o->op_flags & OPf_KIDS) ? OPc_UNOP : OPc_BASEOP;

    case OA_FILESTATOP:
        return ((o->op_flags & OPf_KIDS) ? OPc_UNOP :
#ifdef USE_ITHREADS
                (o->op_flags & OPf_REF) ? OPc_PADOP : OPc_BASEOP);
#else
                (o->op_flags & OPf_REF) ? OPc_SVOP : OPc_BASEOP);
#endif
    case OA_LOOPEXOP:
        if (o->op_flags & OPf_STACKED)
            return OPc_UNOP;
        else if (o->op_flags & OPf_SPECIAL)
            return OPc_BASEOP;
        else
            return OPc_PVOP;
    }
    return OPc_BASEOP;
}

static char *
cc_opclassname(pTHX_ OP *o)
{
    return opclassnames[cc_opclass(aTHX_ o)];
}

/* We return you to optimizer code. */
static SV* peep_in_perl;

void
peep_callback(pTHX_ OP *o)
{
    /* First we convert the op to a B:: object */
    SV* bobject = newSViv(PTR2IV(o));
    sv_setiv(newSVrv(bobject, cc_opclassname(aTHX_ (OP*)o)), PTR2IV(o));

    /* Call the callback */
    {
        dSP;
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(bobject));
        PUTBACK;
        call_sv(peep_in_perl, G_DISCARD);

        FREETMPS;
        LEAVE;
    }

}

static void
uninstall(pTHX)
{
    PL_peepp = Perl_peep;
    sv_free(peep_in_perl);
}

static void
install(pTHX_ SV* subref)
{
    /* We'll do the argument checking in Perl */
    PL_peepp = peep_callback;
    peep_in_perl = newSVsv(subref); /* Copy to be safe */
}

static void
relocatetopad(pTHX_ OP* o)
{
#ifdef USE_ITHREADS
        /* Relocate sv to the pad for thread safety.
         * Despite being a "constant", the SV is written to,
         * for reference counts, sv_upgrade() etc. */
        if (cSVOP->op_sv) {
            PADOFFSET ix = pad_alloc(OP_CONST, SVs_PADTMP);
            if (SvPADTMP(cSVOPo->op_sv)) {
                /* If op_sv is already a PADTMP then it is being used by
                 * some pad, so make a copy. */
                sv_setsv(PL_curpad[ix],cSVOPo->op_sv);
                SvREADONLY_on(PL_curpad[ix]);
                SvREFCNT_dec(cSVOPo->op_sv);
            }
            else {
                SvREFCNT_dec(PL_curpad[ix]);
                SvPADTMP_on(cSVOPo->op_sv);
                PL_curpad[ix] = cSVOPo->op_sv;
                /* XXX I don't know how this isn't readonly already. */
                SvREADONLY_on(PL_curpad[ix]);
            }
            cSVOPo->op_sv = Nullsv;
            o->op_targ = ix;
        }
#endif
}

/* This trick stolen from B.xs */
#define PEEP_op_seqmax() PL_op_seqmax
#define PEEP_op_seqmax_inc() PL_op_seqmax++

MODULE = optimizer		PACKAGE = optimizer		PREFIX = PEEP_

U32
PEEP_op_seqmax()

U32
PEEP_op_seqmax_inc()

void
PEEP_install(SV* subref)
    CODE:
    install(aTHX_ subref);

void
PEEP_uninstall()
    CODE:
    uninstall(aTHX);

void
PEEP_relocatetopad(o)
    B::OP  o
    CODE:
        relocatetopad(aTHX_ o);
