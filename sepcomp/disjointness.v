Require Import ssreflect ssrbool ssrfun seq.
Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Require Import msl.Axioms.

Require Import compcert.common.Memory.
Require Import ZArith.

Require Import sepcomp.StructuredInjections.
Require Import sepcomp.effect_simulations.
Require Import sepcomp.rg_lemmas.
Require Import sepcomp.mem_lemmas.

Require Import sepcomp.inj_lemmas.
Require Import sepcomp.mem_lemmas.
Require Import sepcomp.pred_lemmas.

(* [disjinv] enforces disjointness conditions on the local, public and     *)
(* foreign block sets declared by [mu0] and [mu].  The definition is used  *)
(* to state one of the invariants used in the linking simulation proof.    *)

Record disjinv mu0 mu : Type := 
  { disj_locsrc : Disjoint (locBlocksSrc mu0) (locBlocksSrc mu)
  ; disj_loctgt : Disjoint (locBlocksTgt mu0) (locBlocksTgt mu)
  ; disj_pubfrgnsrc : {subset [predI (frgnBlocksSrc mu) & locBlocksSrc mu0] 
                      <= pubBlocksSrc mu0}
  ; disj_pubfrgntgt : forall b1 b2 d, 
                      foreign_of mu b1 = Some (b2, d) -> 
                      (b1 \in locBlocksSrc mu0) || (b2 \in locBlocksTgt mu0) -> 
                      pub_of mu0 b1 = Some (b2, d)
  ; disj_consistent : consistent (extern_of mu0) (extern_of mu) }.

Lemma disjinv_restrict mu0 mu X : 
  disjinv mu0 mu -> disjinv (restrict_sm mu0 X) (restrict_sm mu X).
Proof.
case=> H H2 H3 H4 H5; apply: Build_disjinv. 
by rewrite !restrict_sm_locBlocksSrc.
by rewrite !restrict_sm_locBlocksTgt.
by rewrite restrict_sm_frgnBlocksSrc restrict_sm_pubBlocksSrc 
           restrict_sm_locBlocksSrc.
rewrite !restrict_sm_foreign=> b1 b2 d. 
rewrite !restrict_sm_pub; rewrite/restrict; case: (X b1)=> //.
by rewrite restrict_sm_locBlocksSrc restrict_sm_locBlocksTgt; apply: H4.
move=> ? ? ? ? ?.
rewrite !restrict_sm_extern.
move/restrictD_Some=> []A _.
move/restrictD_Some=> []B _.
by case: (H5 _ _ _ _ _ A B)=> -> ->.
Qed.

Lemma disjinv_restrict' mu0 mu X : 
  disjinv mu0 mu -> disjinv mu0 (restrict_sm mu X).
Proof.
case=> H H2 H3 H4 H5; apply: Build_disjinv. 
by rewrite !restrict_sm_locBlocksSrc.
by rewrite !restrict_sm_locBlocksTgt.
by rewrite restrict_sm_frgnBlocksSrc.
rewrite !restrict_sm_foreign=> b1 b2 d. 
rewrite/restrict; case: (X b1)=> //.
by apply: H4.
move=> ? ? ? ? ?.
rewrite !restrict_sm_extern=> A; move/restrictD_Some=> []B _.
by case: (H5 _ _ _ _ _ A B)=> -> ->.
Qed.

Lemma disjinv_relat_empty mu : disjinv mu (reestablish Inj.empty mu).
Proof.
apply: Build_disjinv; case: mu=> //=.
by move=> s _ _ _ _ _ _ _ _ _; apply: predI01.
by move=> _ t _ _ _ _ _ _ _ _; apply: predI01. 
move=> _ _ _ _ ? _ _ _ _ extern_of ? ? ? ? ?; rewrite/join=> ->.
by case=> -> ->.
Qed.

Lemma disjinv_call_aux mu0 mu S T :
  {subset (pubBlocksSrc mu0) <= S} -> 
  {subset (pubBlocksTgt mu0) <= T} -> 
  disjinv mu0 mu -> disjinv (replace_locals mu0 S T) mu.
Proof.
move=> H1 H2; case: mu0 H1 H2=> a b c d e a' b' c' d' e' /= H1 H2.
case=> /= A B C D E; apply: Build_disjinv=> //=.
by apply: (subset_trans' _ H1).
move=> b1 b2 d2 H3 H4; move: (D _ _ _ H3 H4); case F: (c b1)=> // H5.
by have ->: (S b1) by apply: H1.
Qed.

Lemma disjinv_call (mu0 : Inj.t) mu m10 m20 vals1 vals2 :
  let: pubSrc := [predI (locBlocksSrc mu0) & REACH m10 (exportedSrc mu0 vals1)] in
  let: pubTgt := [predI (locBlocksTgt mu0) & REACH m20 (exportedTgt mu0 vals2)] in
  let: nu0    := replace_locals mu0 pubSrc pubTgt in
  disjinv mu0 mu -> disjinv nu0 mu.
Proof.
apply: disjinv_call_aux; first by apply: pubBlocksLocReachSrc.
by apply: pubBlocksLocReachTgt.
Qed.

Lemma disjinv_intern_step mu0 (mu mu' : Inj.t) m10 m20 m1 m2 :
  disjinv mu0 mu -> 
  intern_incr mu mu' -> 
  mem_forward m10 m1 -> 
  mem_forward m20 m2 ->   
  sm_inject_separated mu0 mu m10 m20 -> 
  sm_inject_separated mu mu' m1 m2  -> 
  sm_valid mu0 m10 m20 -> 
  sm_valid mu m1 m2 -> 
  disjinv mu0 mu'.
Proof.
move=> inv INCR H3 H4 H5 H6 VAL VAL'.
apply: Build_disjinv. 
+ have A: Disjoint (locBlocksSrc mu0) (locBlocksSrc mu) by case: inv.
  have B: Disjoint (locBlocksSrc mu0) [pred b | ~~ validblock m1 b].
    apply: smvalid_locsrc_disjoint. 
    by apply: (smvalid_src_fwd H3 (sm_valid_smvalid_src _ _ _ VAL)). 
  have C: {subset [predD (locBlocksSrc mu') & locBlocksSrc mu]
          <= [pred b | ~~ validblock m1 b]}.
    by apply: (sminjsep_locsrc INCR VAL').
  have D: Disjoint (locBlocksSrc mu0) 
                   [predD (locBlocksSrc mu') & locBlocksSrc mu].
    by apply: (Disjoint_sub1 B C).
  by apply: (Disjoint_incr A D).
+ have A: Disjoint (locBlocksTgt mu0) (locBlocksTgt mu) by case: inv.
  have B: Disjoint (locBlocksTgt mu0) [pred b | ~~ validblock m2 b].
    apply: smvalid_loctgt_disjoint. 
    by apply: (smvalid_tgt_fwd H4 (sm_valid_smvalid_tgt _ _ _ VAL)). 
  have C: {subset [predD (locBlocksTgt mu') & locBlocksTgt mu]
          <= [pred b | ~~ validblock m2 b]}.
    by apply: (sminjsep_loctgt INCR VAL').
  have D: Disjoint (locBlocksTgt mu0) 
                   [predD (locBlocksTgt mu') & locBlocksTgt mu].
    by apply: (Disjoint_sub1 B C).
  by apply: (Disjoint_incr A D).
+ have A: [predI (frgnBlocksSrc mu') & locBlocksSrc mu0]
          = [predI (frgnBlocksSrc mu) & locBlocksSrc mu0].
    by rewrite (intern_incr_frgnsrc INCR).  
  by rewrite A; case: inv.
+ case: inv; rewrite/foreign_of. 
  generalize dependent mu; generalize dependent mu'.
  case; case=> /= ? ? ? ? ? ? ? ? ? ? ?. 
  case; case=> /= ? ? ? ? ? ? ? ? ? ? ? incr.
  move: (intern_incr_frgnsrc incr) (intern_incr_frgntgt incr)=> /= -> ->.
  by move: (intern_incr_extern incr)=> /= ->.
+ move=> b1 ? ? ? ?; case: INCR=> []_ []<- _ A B; case: inv=> _ _ _ _ C.
  by move: (C _ _ _ _ _ A B); case=> -> ->.
Qed.

Lemma disjinv_unchanged_on_src 
  mu0 mu (E : Values.block -> BinNums.Z -> bool) m m' (val : smvalid_src mu0 m) :
  (forall b ofs, E b ofs -> Mem.valid_block m b -> vis mu b) -> 
  Memory.Mem.unchanged_on (fun b ofs => E b ofs = false) m m' -> 
  disjinv mu0 mu -> 
  Memory.Mem.unchanged_on (fun b => 
    [fun _ => locBlocksSrc mu0 b=true /\ pubBlocksSrc mu0 b=false]) m m'.
Proof.
move=> A B; case=> C _ D _ _; apply: (RGSrc_multicore mu E m m' A B mu0)=> //.
move: C; rewrite DisjointInE=> C.
move=> b F; move: (C b); rewrite/in_mem /=; move/andP=> G.
case H: (locBlocksSrc mu b)=> //; rewrite/in_mem /= H in G; elimtype False.
by apply: G; split.
Qed.

Lemma disjinv_unchanged_on_tgt
  (mu0 mu : Inj.t) (Esrc Etgt : Values.block -> BinNums.Z -> bool)
  m1 m1' m2 m2' (fwd : mem_forward m1 m1') (valid : smvalid_src mu0 m1) :
  (forall (b : Values.block) (ofs : Z),
    Etgt b ofs = true ->
    Mem.valid_block m2 b /\
    (locBlocksTgt mu b = false ->
      exists (b1 : Values.block) (delta1 : Z),
        foreign_of mu b1 = Some (b, delta1) /\
        Esrc b1 (ofs - delta1)%Z = true /\
        Mem.perm m1' b1 (ofs - delta1) Max Nonempty)) -> 
  Mem.unchanged_on (fun b ofs => Etgt b ofs = false) m2 m2' -> 
  disjinv mu0 mu -> 
  Memory.Mem.unchanged_on (local_out_of_reach mu0 m1) m2 m2'.
Proof.
move=> A B; case=> _ D _ E _.
apply: (mem_lemmas.unchanged_on_validblock _ _ _ 
         (local_out_of_reach mu0 m1'))=> //.
move=> b ofs val []F G; split=> // b' d' H; case: (G _ _ H)=> I.
left=> J; apply: I; case: (fwd b')=> //. 
apply: (valid b'); apply/orP; left. 
by case: (local_DomRng mu0 (Inj_wd mu0) _ _ _ H).
by move=> _; apply.
by right.
apply: (RGTgt_multicorePerm mu Etgt Esrc m2 m2' (Inj_wd mu) m1' A B). 
move: D; rewrite DisjointInE=> D.
move=> b F; move: (D b); rewrite/in_mem /=; move/andP=> G.
case H: (locBlocksTgt mu b)=> //; rewrite/in_mem /= H in G; elimtype False.
by apply: G; split.
by apply: E.
Qed.

(* The analogous lemma for extern_incr doesn't appear to hold: *)

(* Lemma disjinv_extern_step (mu0 mu mu' : Inj.t) m10 m20 m1 m2 : *)
(*   disjinv mu0 mu ->  *)
(*   extern_incr mu mu' ->  *)
(*   mem_forward m10 m1 ->  *)
(*   mem_forward m20 m2 ->    *)
(*   sm_inject_separated mu0 mu m10 m20 ->  *)
(*   sm_inject_separated mu mu' m1 m2  ->  *)
(*   sm_valid mu0 m10 m20 ->  *)
(*   disjinv mu0 mu'. *)
(* Proof. *)
(* move=> inv H2 H3 H4 H5 H6 Hvalid; case: H2. *)
(* move=> H7 []H8 []H9 []H10 []H11 []H12 []H13 []H14 []H15 H16. *)
(* apply: Build_disjinv. *)
(* by rewrite -H11; apply: (disj_locsrc inv). *)
(* move=> b A; apply: (disj_pubfrgnsrc inv).  *)
(* move: A; rewrite !in_predI; move/andP=> [].  *)
(* rewrite/in_mem /= => A B; apply/andP; split=> //. *)
(* admit. (*not true?*) *)
(* by rewrite -H12; apply: (disj_loctgt inv). *)
(* move=> b1 b2 d A B.  *)
(* case C: (foreign_of mu b1)=> [[b2' d']|]. *)
(* have D: extern_of mu b1 = Some (b2', d') by apply: foreign_in_extern. *)
(* have E: extern_of mu' b1 = Some (b2, d)  by apply: foreign_in_extern. *)
(* move: (H7 _ _ _ D) B; rewrite E; case=> -> ->. *)
(* by apply: (disj_pubfrgntgt inv). *)
(* case D: (pub_of mu0 b1)=> [[b2' d']|]. admit. (*easy case*) *)
(* admit. (*not true?*) *)
(* Abort. *)