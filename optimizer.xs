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
    PL_curpad = AvARRAY(PL_comppad);

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
relocatetopad(pTHX_ OP* op,CV* cv)
{
#ifdef USE_ITHREADS
        SV** tmp_pad;
	AV* padlist;
	SV** svp;
	SVOP* o = (SVOP*)op;
	padlist = CvPADLIST(cv);
	svp = AvARRAY(padlist);
        tmp_pad = PL_curpad;
	PL_curpad = AvARRAY((AV*)svp[1]);
        /* Relocate sv to the pad for thread safety.
         * Despite being a "constant", the SV is written to,
         * for reference counts, sv_upgrade() etc. */
        if (o->op_sv) {
            PADOFFSET ix = pad_alloc(OP_CONST, SVs_PADTMP);
            if (SvPADTMP(o->op_sv)) {
                /* If op_sv is already a PADTMP then it is being used by
                 * some pad, so make a copy. */
                sv_setsv(PL_curpad[ix],o->op_sv);
                SvREADONLY_on(PL_curpad[ix]);
                SvREFCNT_dec(o->op_sv);
            }
            else {
                SvREFCNT_dec(PL_curpad[ix]);
                SvPADTMP_on(o->op_sv);
                PL_curpad[ix] = o->op_sv;
                /* XXX I don't know how this isn't readonly already. */
                SvREADONLY_on(PL_curpad[ix]);
            }
	    printf("10\n");
            o->op_sv = Nullsv;
            o->op_targ = ix;
	    printf("11\n");
        }
	printf("12\n");
        PL_curpad = tmp_pad;
	printf("13\n");
#endif
}

STATIC void
no_bareword_allowed(pTHX_ OP *o)
{
    qerror(Perl_mess(aTHX_
		     "Bareword \"%s\" not allowed while \"strict subs\" in use",
		     SvPV_nolen(cSVOPo_sv)));
}

void
c_extend_peep(pTHX_ register OP *o)
{
    register OP* oldop = 0;
    STRLEN n_a;

    if (!o || o->op_seq)
	return;
    ENTER;
    SAVEOP();
    SAVEVPTR(PL_curcop);
    for (; o; o = o->op_next) {
	if (o->op_seq)
	    break;
	if (!PL_op_seqmax)
	    PL_op_seqmax++;
	PL_op = o;
	switch (o->op_type) {
	case OP_SETSTATE:
	case OP_NEXTSTATE:
	case OP_DBSTATE:
	    PL_curcop = ((COP*)o);		/* for warnings */
	    o->op_seq = PL_op_seqmax++;
	    break;

	case OP_CONST:
	    if (cSVOPo->op_private & OPpCONST_STRICT)
		no_bareword_allowed(aTHX_ o);
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
	    o->op_seq = PL_op_seqmax++;
	    break;

	case OP_CONCAT:
	    if (o->op_next && o->op_next->op_type == OP_STRINGIFY) {
		if (o->op_next->op_private & OPpTARGET_MY) {
		    if (o->op_flags & OPf_STACKED) /* chained concats */
			goto ignore_optimization;
		    else {
			/* assert(PL_opargs[o->op_type] & OA_TARGLEX); */
			o->op_targ = o->op_next->op_targ;
			o->op_next->op_targ = 0;
			o->op_private |= OPpTARGET_MY;
		    }
		}
		op_null(o->op_next);
	    }
	  ignore_optimization:
	    o->op_seq = PL_op_seqmax++;
	    break;
	case OP_STUB:
	    if ((o->op_flags & OPf_WANT) != OPf_WANT_LIST) {
		o->op_seq = PL_op_seqmax++;
		break; /* Scalar stub must produce undef.  List stub is noop */
	    }
	    goto nothin;
	case OP_NULL:
	    if (o->op_targ == OP_NEXTSTATE
		|| o->op_targ == OP_DBSTATE
		|| o->op_targ == OP_SETSTATE)
	    {
		PL_curcop = ((COP*)o);
	    }
	    /* XXX: We avoid setting op_seq here to prevent later calls
	       to peep() from mistakenly concluding that optimisation
	       has already occurred. This doesn't fix the real problem,
	       though (See 20010220.007). AMS 20010719 */
	    if (oldop && o->op_next) {
		oldop->op_next = o->op_next;
		continue;
	    }
	    break;
	case OP_SCALAR:
	case OP_LINESEQ:
	case OP_SCOPE:
	  nothin:
	    if (oldop && o->op_next) {
		oldop->op_next = o->op_next;
		continue;
	    }
	    o->op_seq = PL_op_seqmax++;
	    break;

	case OP_GV:
	    if (o->op_next->op_type == OP_RV2SV) {
		if (!(o->op_next->op_private & OPpDEREF)) {
		    op_null(o->op_next);
		    o->op_private |= o->op_next->op_private & (OPpLVAL_INTRO
							       | OPpOUR_INTRO);
		    o->op_next = o->op_next->op_next;
		    o->op_type = OP_GVSV;
		    o->op_ppaddr = PL_ppaddr[OP_GVSV];
		}
	    }
	    else if (o->op_next->op_type == OP_RV2AV) {
		OP* pop = o->op_next->op_next;
		IV i;
		if (pop && pop->op_type == OP_CONST &&
		    (PL_op = pop->op_next) &&
		    pop->op_next->op_type == OP_AELEM &&
		    !(pop->op_next->op_private &
		      (OPpLVAL_INTRO|OPpLVAL_DEFER|OPpDEREF|OPpMAYBE_LVSUB)) &&
		    (i = SvIV(((SVOP*)pop)->op_sv) - PL_curcop->cop_arybase)
				<= 255 &&
		    i >= 0)
		{
		    GV *gv;
		    op_null(o->op_next);
		    op_null(pop->op_next);
		    op_null(pop);
		    o->op_flags |= pop->op_next->op_flags & OPf_MOD;
		    o->op_next = pop->op_next->op_next;
		    o->op_type = OP_AELEMFAST;
		    o->op_ppaddr = PL_ppaddr[OP_AELEMFAST];
		    o->op_private = (U8)i;
		    gv = cGVOPo_gv;
		    GvAVn(gv);
		}
	    }
	    else if ((o->op_private & OPpEARLY_CV) && ckWARN(WARN_PROTOTYPE)) {
		GV *gv = cGVOPo_gv;
		if (SvTYPE(gv) == SVt_PVGV && GvCV(gv) && SvPVX(GvCV(gv))) {
		    /* XXX could check prototype here instead of just carping */
		    SV *sv = sv_newmortal();
		    gv_efullname3(sv, gv, Nullch);
		    Perl_warner(aTHX_ packWARN(WARN_PROTOTYPE),
				"%s() called too early to check prototype",
				SvPV_nolen(sv));
		}
	    }
	    else if (o->op_next->op_type == OP_READLINE
		    && o->op_next->op_next->op_type == OP_CONCAT
		    && (o->op_next->op_next->op_flags & OPf_STACKED))
	    {
		/* Turn "$a .= <FH>" into an OP_RCATLINE. AMS 20010917 */
		o->op_type   = OP_RCATLINE;
		o->op_flags |= OPf_STACKED;
		o->op_ppaddr = PL_ppaddr[OP_RCATLINE];
		op_null(o->op_next->op_next);
		op_null(o->op_next);
	    }

	    o->op_seq = PL_op_seqmax++;
	    break;

	case OP_MAPWHILE:
	case OP_GREPWHILE:
	case OP_AND:
	case OP_OR:
	case OP_ANDASSIGN:
	case OP_ORASSIGN:
	case OP_COND_EXPR:
	case OP_RANGE:
	    o->op_seq = PL_op_seqmax++;
	    while (cLOGOP->op_other->op_type == OP_NULL)
		cLOGOP->op_other = cLOGOP->op_other->op_next;
	    c_extend_peep(aTHX_ cLOGOP->op_other); /* Recursive calls are not replaced by fptr calls */
	    break;

	case OP_ENTERLOOP:
	case OP_ENTERITER:
	    o->op_seq = PL_op_seqmax++;
	    while (cLOOP->op_redoop->op_type == OP_NULL)
		cLOOP->op_redoop = cLOOP->op_redoop->op_next;
	    c_extend_peep(aTHX_ cLOOP->op_redoop);
	    while (cLOOP->op_nextop->op_type == OP_NULL)
		cLOOP->op_nextop = cLOOP->op_nextop->op_next;
	    c_extend_peep(aTHX_ cLOOP->op_nextop);
	    while (cLOOP->op_lastop->op_type == OP_NULL)
		cLOOP->op_lastop = cLOOP->op_lastop->op_next;
	    c_extend_peep(aTHX_ cLOOP->op_lastop);
	    break;

	case OP_QR:
	case OP_MATCH:
	case OP_SUBST:
	    o->op_seq = PL_op_seqmax++;
	    while (cPMOP->op_pmreplstart &&
		   cPMOP->op_pmreplstart->op_type == OP_NULL)
		cPMOP->op_pmreplstart = cPMOP->op_pmreplstart->op_next;
	    c_extend_peep(aTHX_ cPMOP->op_pmreplstart);
	    break;

	case OP_EXEC:
	    o->op_seq = PL_op_seqmax++;
	    if (ckWARN(WARN_SYNTAX) && o->op_next
		&& o->op_next->op_type == OP_NEXTSTATE) {
		if (o->op_next->op_sibling &&
			o->op_next->op_sibling->op_type != OP_EXIT &&
			o->op_next->op_sibling->op_type != OP_WARN &&
			o->op_next->op_sibling->op_type != OP_DIE) {
		    line_t oldline = CopLINE(PL_curcop);

		    CopLINE_set(PL_curcop, CopLINE((COP*)o->op_next));
		    Perl_warner(aTHX_ packWARN(WARN_EXEC),
				"Statement unlikely to be reached");
		    Perl_warner(aTHX_ packWARN(WARN_EXEC),
				"\t(Maybe you meant system() when you said exec()?)\n");
		    CopLINE_set(PL_curcop, oldline);
		}
	    }
	    break;

	case OP_HELEM: {
	    UNOP *rop;
	    SV *lexname;
	    GV **fields;
	    SV **svp, **indsvp, *sv;
	    I32 ind;
	    char *key = NULL;
	    STRLEN keylen;

	    o->op_seq = PL_op_seqmax++;

	    if (((BINOP*)o)->op_last->op_type != OP_CONST)
		break;

	    /* Make the CONST have a shared SV */
	    svp = cSVOPx_svp(((BINOP*)o)->op_last);
	    if ((!SvFAKE(sv = *svp) || !SvREADONLY(sv)) && !IS_PADCONST(sv)) {
		key = SvPV(sv, keylen);
		lexname = newSVpvn_share(key,
					 SvUTF8(sv) ? -(I32)keylen : keylen,
					 0);
		SvREFCNT_dec(sv);
		*svp = lexname;
	    }

	    if ((o->op_private & (OPpLVAL_INTRO)))
		break;

	    rop = (UNOP*)((BINOP*)o)->op_first;
	    if (rop->op_type != OP_RV2HV || rop->op_first->op_type != OP_PADSV)
		break;
	    lexname = *av_fetch(PL_comppad_name, rop->op_first->op_targ, TRUE);
	    if (!(SvFLAGS(lexname) & SVpad_TYPED))
		break;
	    fields = (GV**)hv_fetch(SvSTASH(lexname), "FIELDS", 6, FALSE);
	    if (!fields || !GvHV(*fields))
		break;
	    key = SvPV(*svp, keylen);
	    indsvp = hv_fetch(GvHV(*fields), key,
			      SvUTF8(*svp) ? -(I32)keylen : keylen, FALSE);
	    if (!indsvp) {
		Perl_croak(aTHX_ "No such pseudo-hash field \"%s\" in variable %s of type %s",
		      key, SvPV(lexname, n_a), HvNAME(SvSTASH(lexname)));
	    }
	    ind = SvIV(*indsvp);
	    if (ind < 1)
		Perl_croak(aTHX_ "Bad index while coercing array into hash");
	    rop->op_type = OP_RV2AV;
	    rop->op_ppaddr = PL_ppaddr[OP_RV2AV];
	    o->op_type = OP_AELEM;
	    o->op_ppaddr = PL_ppaddr[OP_AELEM];
	    sv = newSViv(ind);
	    if (SvREADONLY(*svp))
		SvREADONLY_on(sv);
	    SvFLAGS(sv) |= (SvFLAGS(*svp)
			    & (SVs_PADBUSY|SVs_PADTMP|SVs_PADMY));
	    SvREFCNT_dec(*svp);
	    *svp = sv;
	    break;
	}

	case OP_HSLICE: {
	    UNOP *rop;
	    SV *lexname;
	    GV **fields;
	    SV **svp, **indsvp, *sv;
	    I32 ind;
	    char *key;
	    STRLEN keylen;
	    SVOP *first_key_op, *key_op;

	    o->op_seq = PL_op_seqmax++;
	    if ((o->op_private & (OPpLVAL_INTRO))
		/* I bet there's always a pushmark... */
		|| ((LISTOP*)o)->op_first->op_sibling->op_type != OP_LIST)
		/* hmmm, no optimization if list contains only one key. */
		break;
	    rop = (UNOP*)((LISTOP*)o)->op_last;
	    if (rop->op_type != OP_RV2HV || rop->op_first->op_type != OP_PADSV)
		break;
	    lexname = *av_fetch(PL_comppad_name, rop->op_first->op_targ, TRUE);
	    if (!(SvFLAGS(lexname) & SVpad_TYPED))
		break;
	    fields = (GV**)hv_fetch(SvSTASH(lexname), "FIELDS", 6, FALSE);
	    if (!fields || !GvHV(*fields))
		break;
	    /* Again guessing that the pushmark can be jumped over.... */
	    first_key_op = (SVOP*)((LISTOP*)((LISTOP*)o)->op_first->op_sibling)
		->op_first->op_sibling;
	    /* Check that the key list contains only constants. */
	    for (key_op = first_key_op; key_op;
		 key_op = (SVOP*)key_op->op_sibling)
		if (key_op->op_type != OP_CONST)
		    break;
	    if (key_op)
		break;
	    rop->op_type = OP_RV2AV;
	    rop->op_ppaddr = PL_ppaddr[OP_RV2AV];
	    o->op_type = OP_ASLICE;
	    o->op_ppaddr = PL_ppaddr[OP_ASLICE];
	    for (key_op = first_key_op; key_op;
		 key_op = (SVOP*)key_op->op_sibling) {
		svp = cSVOPx_svp(key_op);
		key = SvPV(*svp, keylen);
		indsvp = hv_fetch(GvHV(*fields), key,
				  SvUTF8(*svp) ? -(I32)keylen : keylen, FALSE);
		if (!indsvp) {
		    Perl_croak(aTHX_ "No such pseudo-hash field \"%s\" "
			       "in variable %s of type %s",
			  key, SvPV(lexname, n_a), HvNAME(SvSTASH(lexname)));
		}
		ind = SvIV(*indsvp);
		if (ind < 1)
		    Perl_croak(aTHX_ "Bad index while coercing array into hash");
		sv = newSViv(ind);
		if (SvREADONLY(*svp))
		    SvREADONLY_on(sv);
		SvFLAGS(sv) |= (SvFLAGS(*svp)
				& (SVs_PADBUSY|SVs_PADTMP|SVs_PADMY));
		SvREFCNT_dec(*svp);
		*svp = sv;
	    }
	    break;
	}

	default:
	    o->op_seq = PL_op_seqmax++;
	    break;
	}
	peep_callback(aTHX_ o);
	oldop = o;
    }
    LEAVE;
}

void
c_sub_detect(pTHX_ register OP *o)
{

  /* Here we call the perl peep function so we don't get bit by
     by the fact that doing stuff while optimization is highly dangerous
  */
    
  peep(o);
    
  /* Since we get the start here, we should try and find the
     leave by following next until we find it
  */

  while(o) {
    if(o->op_next) 
      o = o->op_next;
    else 
      break;
  }
  if(o->op_type == OP_LEAVESUB   ||
     o->op_type == OP_LEAVESUBLV ||
     o->op_type == OP_LEAVE      ||
     o->op_type == OP_LEAVEEVAL) {
      peep_callback(aTHX_ o);
  }

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
PEEP_c_extend_install(SV* subref)
     CODE:
     PL_peepp = c_extend_peep;
     peep_in_perl = newSVsv(subref);

void
PEEP_c_sub_detect_install(SV* subref)
     CODE:
     PL_peepp = c_sub_detect;
     peep_in_perl = newSVsv(subref);

void
PEEP_install(SV* subref)
    CODE:
    install(aTHX_ subref);

void
PEEP_uninstall()
    CODE:
    uninstall(aTHX);

void
PEEP_relocatetopad(o,sv)
    B::OP  o
    SV*  sv
    CODE:
        sv = (SV*) SvIV(SvRV(sv));
        relocatetopad(aTHX_ o,(CV*)sv);
