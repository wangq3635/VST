Require Import sepcomp.compcert. Import CompcertAll.

Require Import sepcomp.core_semantics.
Require Import sepcomp.core_semantics_lemmas.
Require Import sepcomp.mem_wd.
Require Import sepcomp.mem_lemmas.
Require Import sepcomp.reach.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Definition oval_valid (ov : option val) (m : mem) :=
  match ov with
    | None => True
    | Some v => val_valid v m
  end.

Lemma valid_genv_isGlobal F V (ge : Genv.t F V) m b : 
  valid_genv ge m -> 
  isGlobalBlock ge b=true -> 
  Mem.valid_block m b.
Proof.
intros H H2.
destruct H.
unfold isGlobalBlock in H2.
rewrite orb_true_iff in H2.
unfold genv2blocksBool in H2; simpl in H2.
destruct H2.
generalize H1; case_eq (Genv.invert_symbol ge b).
intros i inv _; apply Genv.invert_find_symbol in inv.
apply (H _ _ inv).
intros none; rewrite none in H1; discriminate.
revert H1; case_eq (Genv.find_var_info ge b).
intros gv fnd _.
apply (H0 _ _ fnd).
discriminate.
Qed.

Lemma mem_wd_reach m : 
  mem_wd m -> 
  forall b, 
  REACH m (fun b => valid_block_dec m b) b=true -> 
  Mem.valid_block m b.
Proof. 
intros H b H2.
rewrite REACHAX in H2.
destruct H2 as [L H3].
revert b H3; induction L; simpl.
intros b; inversion 1; subst.
revert H0; case_eq (valid_block_dec m b); auto.
intros. inversion H1.
intros b; inversion 1; subst.
specialize (IHL b' H2).
assert (A: Mem.flat_inj (Mem.nextblock m) b' = Some (b',0)).
{ unfold Mem.flat_inj.
  case_eq (plt b' (Mem.nextblock m)); intros p _; auto.
  elimtype False; apply p; apply IHL. }
destruct H; specialize (mi_memval _ _ _ _ A H4).
rewrite H6 in mi_memval; inversion mi_memval; subst.
revert H1; unfold Mem.flat_inj.
case_eq (plt b (Mem.nextblock m)); auto.
intros p _; inversion 1.
Qed.

Lemma mem_wd_reach_globargs F V (ge : Genv.t F V) vs m : 
  mem_wd m -> 
  Forall (fun v => val_valid v m) vs -> 
  valid_genv ge m -> 
  forall b, 
    REACH m (fun b => 
      (isGlobalBlock ge b || getBlocks vs b)) b=true -> 
    Mem.valid_block m b.
Proof. 
intros H H1 H2 b H3.
rewrite REACHAX in H3.
destruct H3 as [L H3].
revert b H3; induction L; simpl.
intros b; inversion 1; subst.
rewrite orb_true_iff in H0.
destruct H0.
unfold valid_genv in H2.
eapply valid_genv_isGlobal; eauto.
rewrite getBlocks_char in H0.
destruct H0.
clear - H1 H0.
induction vs. inversion H0.
inversion H1; subst. 
inversion H0; subst.
apply H3. apply IHvs; auto. 
intros b; inversion 1; subst.
specialize (IHL b' H5).
destruct H.
assert (A: Mem.flat_inj (Mem.nextblock m) b' = Some (b',0)).
{ unfold Mem.flat_inj.
  case_eq (plt b' (Mem.nextblock m)); intros p _; auto.
  elimtype False; apply p; apply IHL. }
specialize (mi_memval _ _ _ _ A H6).
rewrite H8 in mi_memval.
inversion mi_memval; subst.
unfold Mem.flat_inj in H4.
generalize H4.
case_eq (plt b (Mem.nextblock m)); auto.
intros p _; inversion 1.
Qed.

Module Nuke. Section nucular_semantics.

Variable F V C : Type.

Variable csem : CoreSemantics (Genv.t F V) C mem.

Record nucular_semantics : Type :=
{ I : C -> mem -> Prop

; wmd_initial : 
    forall ge m v args c,
    Forall (fun v => val_valid v m) args -> 
    valid_genv ge m -> 
    mem_wd m -> 
    initial_core csem ge v args = Some c -> 
    I c m

; wmd_corestep : 
    forall ge c m c' m',
    corestep csem ge c m c' m' -> 
    valid_genv ge m ->
    I c m -> 
    I c' m'

; wmd_at_external :
    forall (ge : Genv.t F V) c m ef dep_sig args,
    I c m -> 
    at_external csem c = Some (ef,dep_sig,args) -> 
    Forall (fun v => val_valid v m) args /\ mem_wd m

; wmd_after_external :
    forall c m ov c' m',
    I c m -> 
    after_external csem ov c = Some c' -> 
    oval_valid ov m' -> 
    mem_forward m m' -> 
    I c' m' 

; wmd_halted : 
    forall c m v,
    I c m -> 
    halted csem c = Some v -> 
    val_valid v m }.

End nucular_semantics.

Lemma val_valid_fwd v m m' : 
  val_valid v m -> 
  mem_forward m m' -> 
  val_valid v m'.
Proof. solve[destruct v; auto; simpl; intros H H2; apply H2; auto]. Qed.

Lemma valid_genv_fwd F V (ge : Genv.t F V) m m' :
  valid_genv ge m -> 
  mem_forward m m' -> 
  valid_genv ge m'.
Proof.
intros H fwd. destruct H as [A B]. split.
{ intros id b fnd.
cut (val_valid (Vptr b Int.zero) m). 
+ intros H2; apply (val_valid_fwd H2 fwd).
+ specialize (A id b fnd); auto. }
{ intros gv b H.
cut (val_valid (Vptr b Int.zero) m). 
+ intros H2; apply (val_valid_fwd H2 fwd).
+ specialize (B gv b); auto. }
Qed.

Lemma valid_genv_step F V C (ge : Genv.t F V) 
    (csem : CoopCoreSem (Genv.t F V) C) c m c' m' : 
  valid_genv ge m -> 
  corestep csem ge c m c' m' -> 
  valid_genv ge m'.
Proof.
intros H step; apply corestep_fwd in step; eapply valid_genv_fwd; eauto.
Qed.

Lemma valid_genv_stepN F V C (ge : Genv.t F V) 
    (csem : CoopCoreSem (Genv.t F V) C) c m c' m' n : 
  valid_genv ge m -> 
  corestepN csem ge n c m c' m' -> 
  valid_genv ge m'.
Proof.
intros H stepn; apply corestepN_fwd in stepn; eapply valid_genv_fwd; eauto.
Qed.

Section nucular_semantics_lemmas.

Variable F V C : Type.

Variable csem : CoopCoreSem (Genv.t F V) C.

Variable nuke : nucular_semantics csem.

Variable ge : Genv.t F V.

Lemma nucular_stepN c m (H : nuke.(I) c m) c' m' n : 
  valid_genv ge m -> 
  corestepN csem ge n c m c' m' -> 
  nuke.(I) c' m'.
Proof.
revert c m H; induction n; simpl.
solve[intros ? ? ? ?; inversion 1; subst; auto].
intros c m H H2 [c2 [m2 [H3 H4]]].
apply (IHn c2 m2); auto.
solve[eapply wmd_corestep in H3; eauto].
solve[apply (valid_genv_step H2 H3)].
Qed.

End nucular_semantics_lemmas. 

End Nuke.