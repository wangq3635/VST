Require Import Coq.Sorting.Permutation.
Require Import Coq.Sorting.Sorting.
Require Import Coq.Structures.Orders.
Require Import VST.veric.base.
Require Import VST.veric.Clight_lemmas.
Require Import VST.veric.type_induction.
Require Import VST.veric.composite_compute.

(* This file contains three computational align criteria.
   1: the hardware alignof is not larger than alignof.
   2: all fields are aligned as hardware requires. size as a multiple of hardware alignof.
   3: all value is well-aligned stored.
   The third one is the final specification we want. *)

Section align_compatible_rec.

Context (cenv: composite_env).

Inductive align_compatible_rec: type -> Z -> Prop :=
| align_compatible_rec_by_value: forall t ch z, access_mode t = By_value ch -> (Memdata.align_chunk ch | z) -> align_compatible_rec t z
| align_compatible_rec_Tarray: forall t n a z, (forall i, 0 <= i < n -> align_compatible_rec t (z + sizeof cenv t * i)) -> align_compatible_rec (Tarray t n a) z
| align_compatible_rec_Tstruct: forall i a co z, cenv ! i = Some co -> (forall i0 t0 z0, field_type i0 (co_members co) = Errors.OK t0 -> field_offset cenv i0 (co_members co) = Errors.OK z0 -> align_compatible_rec t0 (z + z0)) -> align_compatible_rec (Tstruct i a) z
| align_compatible_rec_Tunion: forall i a co z, cenv ! i = Some co -> (forall i0 t0, field_type i0 (co_members co) = Errors.OK t0 -> align_compatible_rec t0 z) -> align_compatible_rec (Tunion i a) z.

End align_compatible_rec.

Lemma align_chunk_1248: forall ch, align_chunk ch = 1 \/ align_chunk ch = 2 \/ align_chunk ch = 4 \/ align_chunk ch = 8.
Proof.
  intros.
  destruct ch; simpl;
  auto.
Qed.

Lemma align_chunk_two_p:
  forall ch, exists n, align_chunk ch = two_power_nat n.
Proof.
  intros.
  pose proof align_chunk_1248 ch as [| [| [|]]]; rewrite H.
  + exists 0%nat; auto.
  + exists 1%nat; auto.
  + exists 2%nat; auto.
  + exists 3%nat; auto.
Qed.

Fixpoint hardware_alignof (ha_env: PTree.t Z) t: Z :=
  match t with
  | Tarray t' _ _ => hardware_alignof ha_env t'
  | Tstruct id _ =>
      match ha_env ! id with
      | Some ha => ha
      | None => 1
      end
  | Tunion id _ =>
      match ha_env ! id with
      | Some ha => ha
      | None => 1
      end
  | _ => match access_mode t with
         | By_value ch => Memdata.align_chunk ch
         | _ => 1
         end
  end.

Fixpoint hardware_alignof_composite (ha_env: PTree.t Z) (m: members): Z :=
  match m with
  | nil => 1
  | (_, t) :: m' => Z.max (hardware_alignof ha_env t) (hardware_alignof_composite ha_env m')
  end.

Definition hardware_alignof_env (cenv: composite_env): PTree.t Z :=
  let l := composite_reorder.rebuild_composite_elements cenv in
  fold_right (fun (ic: positive * composite) (T0: PTree.t Z) => let (i, co) := ic in let T := T0 in PTree.set i (hardware_alignof_composite T (co_members co)) T) (PTree.empty _) l.

Definition hardware_alignof_env_consistent (cenv: composite_env) (ha_env: PTree.t Z): Prop :=
  forall i co ha,
    cenv ! i = Some co ->
    ha_env ! i = Some ha ->
    ha = hardware_alignof_composite ha_env (co_members co).

Definition hardware_alignof_env_complete (cenv: composite_env) (ha_env: PTree.t Z): Prop :=
  forall i,
    (exists co, cenv ! i = Some co) <->
    (exists ha, ha_env ! i = Some ha).

Module Type HARDWARE_ALIGNOF_FACTS.

  Axiom hardware_alignof_consistency:
    forall (cenv: composite_env) (ha_env: PTree.t Z),
      composite_env_consistent cenv ->
      ha_env = hardware_alignof_env cenv ->
      hardware_alignof_env_consistent cenv ha_env.

  Axiom hardware_alignof_completeness:
    forall (cenv: composite_env) (ha_env: PTree.t Z),
      ha_env = hardware_alignof_env cenv ->
      hardware_alignof_env_complete cenv ha_env.

End HARDWARE_ALIGNOF_FACTS.

Module hardware_alignof_facts: HARDWARE_ALIGNOF_FACTS.

Lemma aux1: forall T co,
  (fix fm (l : list (ident * type * Z)) : Z :=
     match l with
     | nil => 1
     | (_, _, ha) :: l' => Z.max ha (fm l')
     end)
    (map
       (fun it0 : positive * type =>
        let (i0, t0) := it0 in
        (i0, t0,
        type_func.F
          (fun t : type =>
           match access_mode t with
           | By_value ch => align_chunk ch
           | By_reference => 1
           | By_copy => 1
           | By_nothing => 1
           end) (fun (ha : Z) (_ : type) (_: Z) (_ : attr) => ha)
          (fun (ha : Z) (_ : ident) (_ : attr) => ha)
          (fun (ha : Z) (_ : ident) (_ : attr) => ha) T t0)) (co_members co)) =
                    hardware_alignof_composite T (co_members co).
Proof.
  intros; unfold hardware_alignof_composite, hardware_alignof.
  induction (co_members co) as [| [i t] ?].
  + auto.
  + simpl.
    f_equal; auto.
    clear.
    induction t; auto.
Qed.

Lemma aux2: forall (cenv: composite_env),
  type_func.Env
          (fun t : type =>
           match access_mode t with
           | By_value ch => align_chunk ch
           | By_reference => 1
           | By_copy => 1
           | By_nothing => 1
           end) (fun (ha : Z) (_ : type) (_: Z) (_ : attr) => ha)
          (fun (ha : Z) (_ : ident) (_ : attr) => ha)
          (fun (ha : Z) (_ : ident) (_ : attr) => ha)
          (fun _ : struct_or_union =>
           fix fm (l : list (ident * type * Z)) : Z :=
             match l with
             | nil => 1
             | (_, _, ha) :: l' => Z.max ha (fm l')
             end) (composite_reorder.rebuild_composite_elements cenv) =
  hardware_alignof_env cenv.
Proof.
  intros.
  unfold type_func.Env, type_func.env_rec, hardware_alignof_env.
  f_equal.
  extensionality ic.
  destruct ic as [i co].
  extensionality T.
  f_equal.
  apply aux1.
Qed.

Lemma hardware_alignof_consistency (cenv: composite_env) (ha_env: PTree.t Z):
  composite_env_consistent cenv ->
  ha_env = hardware_alignof_env cenv ->
  forall i co ha,
    cenv ! i = Some co ->
    ha_env ! i = Some ha ->
    ha = hardware_alignof_composite ha_env (co_members co).
Proof.
  intros.
  pose proof @composite_reorder_consistent Z cenv
             (fun t =>
                match access_mode t with
                | By_value ch => Memdata.align_chunk ch
                | _ => 1
                end)
             (fun ha _ _ _ => ha)
             (fun ha _ _ => ha)
             (fun ha _ _ => ha)
             (fun _ =>
                fix fm (l: list (ident * type * Z)): Z :=
                match l with
                | nil => 1
                | (_, _, ha) :: l' => Z.max ha (fm l')
                end)
             H
    as HH.
  hnf in HH.
  subst ha_env.
  rewrite aux2 in HH.
  specialize (HH _ _ ha H1 H2).
  rewrite HH, aux1; auto.
Qed.

Lemma hardware_alignof_completeness (cenv: composite_env) (ha_env: PTree.t Z):
  ha_env = hardware_alignof_env cenv ->
  forall i,
    (exists co, cenv ! i = Some co) <->
    (exists ha, ha_env ! i = Some ha).
Proof.
  intros.
  pose proof @composite_reorder_complete Z cenv
             (fun t =>
                match access_mode t with
                | By_value ch => Memdata.align_chunk ch
                | _ => 1
                end)
             (fun ha _ _ _ => ha)
             (fun ha _ _ => ha)
             (fun ha _ _ => ha)
             (fun _ =>
                fix fm (l: list (ident * type * Z)): Z :=
                match l with
                | nil => 1
                | (_, _, ha) :: l' => Z.max ha (fm l')
                end)
    as HH.
  hnf in HH.
  subst.
  rewrite aux2 in HH.
  auto.
Qed.

End hardware_alignof_facts.

Export hardware_alignof_facts.

Lemma hardware_alignof_two_p: forall (cenv: composite_env) (ha_env: PTree.t Z),
  composite_env_consistent cenv ->
  hardware_alignof_env_consistent cenv ha_env ->  
  hardware_alignof_env_complete cenv ha_env ->  
  forall t, exists n,
  hardware_alignof ha_env t = two_power_nat n.
Proof.
  intros ? ? CENV_CONS HA_ENV_CONS HA_ENV_COMPL ?.
  type_induction t cenv CENV_CONS.
  + exists 0%nat; reflexivity.
  + destruct s, i; try solve [exists 0%nat; reflexivity | exists 1%nat; reflexivity | exists 2%nat; reflexivity | exists 3%nat; reflexivity].
  + destruct s; try solve [exists 0%nat; reflexivity | exists 1%nat; reflexivity | exists 2%nat; reflexivity | exists 3%nat; reflexivity].
  + destruct f; try solve [exists 0%nat; reflexivity | exists 1%nat; reflexivity | exists 2%nat; reflexivity | exists 3%nat; reflexivity].
  + exists 2%nat; reflexivity.
  + simpl.
    auto.
  + exists 0%nat; reflexivity.
  + simpl.
    pose proof HA_ENV_CONS id; pose proof HA_ENV_COMPL id.
    destruct (cenv ! id) as [co |] eqn:?H, (ha_env ! id) eqn:?H.
    Focus 2. { pose proof proj1 H0 (ex_intro _ _ eq_refl) as [? ?]; congruence. } Unfocus.
    Focus 2. { pose proof proj2 H0 (ex_intro _ _ eq_refl) as [? ?]; congruence. } Unfocus.
    - specialize (H _ _ eq_refl eq_refl).
      subst z.
      clear - IH.
      induction IH.
      * exists 0%nat; reflexivity.
      * destruct x as [i t], H as [n1 ?], IHIH as [n2 ?].
        simpl in H |- *.
        rewrite H, H0.
        rewrite max_two_power_nat.
        eexists; reflexivity.
    - exists 0%nat; reflexivity.
  + simpl.
    pose proof HA_ENV_CONS id; pose proof HA_ENV_COMPL id.
    destruct (cenv ! id) as [co |] eqn:?H, (ha_env ! id) eqn:?H.
    Focus 2. { pose proof proj1 H0 (ex_intro _ _ eq_refl) as [? ?]; congruence. } Unfocus.
    Focus 2. { pose proof proj2 H0 (ex_intro _ _ eq_refl) as [? ?]; congruence. } Unfocus.
    - specialize (H _ _ eq_refl eq_refl).
      subst z.
      clear - IH.
      induction IH.
      * exists 0%nat; reflexivity.
      * destruct x as [i t], H as [n1 ?], IHIH as [n2 ?].
        simpl in H |- *.
        rewrite H, H0.
        rewrite max_two_power_nat.
        eexists; reflexivity.
    - exists 0%nat; reflexivity.
Qed.

Lemma hardware_alignof_pos: forall (cenv: composite_env) (ha_env: PTree.t Z),
  composite_env_consistent cenv ->
  hardware_alignof_env_consistent cenv ha_env ->  
  hardware_alignof_env_complete cenv ha_env ->  
  forall t,
  hardware_alignof ha_env t > 0.
Proof.
  intros.
  pose proof hardware_alignof_two_p _ _ H H0 H1 t as [n ?].
  rewrite H2.
  apply two_power_nat_pos.
Qed.

Module Type LEGAL_ALIGNAS.

  Parameter obs: Type.
  Parameter legal_alignas_type: composite_env -> PTree.t Z -> PTree.t obs -> type -> obs.
  Parameter legal_alignas_composite: composite_env -> PTree.t Z -> PTree.t obs -> members -> obs.
  Parameter legal_alignas_env: composite_env -> PTree.t Z -> PTree.t obs.
  Parameter is_aligned: obs -> Z -> Z -> bool.

  Definition legal_alignas_env_consistent (cenv: composite_env) (ha_env: PTree.t Z) (la_env: PTree.t obs): Prop :=
    forall i co la,
      cenv ! i = Some co ->
      la_env ! i = Some la ->
      la = legal_alignas_composite cenv ha_env la_env (co_members co).

  Definition legal_alignas_env_complete (cenv: composite_env) (la_env: PTree.t obs): Prop :=
    forall i,
      (exists co, cenv ! i = Some co) <->
      (exists la, la_env ! i = Some la).

  Definition legal_alignas_env_sound (cenv: composite_env) (ha_env: PTree.t Z) (la_env: PTree.t obs): Prop :=
    forall ofs t,
      is_aligned (legal_alignas_type cenv ha_env la_env t) (hardware_alignof ha_env t) ofs = true ->
      align_compatible_rec cenv t ofs.

  Axiom legal_alignas_env_consistency: forall cenv ha_env,
    composite_env_consistent cenv ->
    legal_alignas_env_consistent cenv ha_env (legal_alignas_env cenv ha_env).

  Axiom legal_alignas_env_completeness: forall cenv ha_env,
    legal_alignas_env_complete cenv (legal_alignas_env cenv ha_env).

  Axiom legal_alignas_soundness: forall cenv ha_env la_env,
    legal_alignas_env_consistent cenv ha_env la_env ->
    legal_alignas_env_complete cenv la_env ->
    legal_alignas_env_sound cenv ha_env la_env.

End LEGAL_ALIGNAS.

Module LegalAlignasStrict.

Section legal_alignas.

Context (cenv: composite_env) (ha_env: PTree.t Z).

Definition obs: Type := bool.

Fixpoint legal_alignas_type (la_env: PTree.t bool) t: bool :=
  (hardware_alignof ha_env t <=? alignof cenv t) &&
  match t with
  | Tarray t' _ _ => legal_alignas_type la_env t'
  | Tstruct id _ =>
      match la_env ! id with
      | Some la => la
      | None => false
      end
  | Tunion id _ =>
      match la_env ! id with
      | Some la => la
      | None => false
      end
  | _ => match access_mode t with
         | By_value ch => true
         | _ => false
         end
  end.

Fixpoint legal_alignas_composite (la_env: PTree.t bool) (m: members): bool :=
  match m with
  | nil => true
  | (_, t) :: m' => (legal_alignas_type la_env t) && (legal_alignas_composite la_env m')
  end.

Definition legal_alignas_env: PTree.t bool :=
  let l := composite_reorder.rebuild_composite_elements cenv in
  fold_right (fun (ic: positive * composite) (T0: PTree.t bool) => let (i, co) := ic in let T := T0 in PTree.set i (legal_alignas_composite T (co_members co)) T) (PTree.empty _) l.

Definition is_aligned (b: bool) (ha: Z) (ofs: Z) := b && ((ofs mod ha) =? 0).

Definition legal_alignas_env_consistent (la_env: PTree.t obs): Prop :=
  forall i co la,
    cenv ! i = Some co ->
    la_env ! i = Some la ->
    la = legal_alignas_composite la_env (co_members co).

Definition legal_alignas_env_complete (la_env: PTree.t obs): Prop :=
  forall i,
    (exists co, cenv ! i = Some co) <->
    (exists la, la_env ! i = Some la).

Definition legal_alignas_env_sound (la_env: PTree.t obs): Prop :=
  forall ofs t,
    is_aligned (legal_alignas_type la_env t) (hardware_alignof ha_env t) ofs = true ->
    align_compatible_rec cenv t ofs.

End legal_alignas.

Lemma aux1: forall cenv ha_env T co,
      (fix fm (l : list (ident * type * bool)) : bool :=
          match l with
          | nil => true
          | (_, _, la) :: l' => la && fm l'
          end)
         (map
            (fun it0 : positive * type =>
             let (i0, t0) := it0 in
             (i0, t0,
             type_func.F
               (fun t : type =>
                (hardware_alignof ha_env t <=? alignof cenv t) &&
                match access_mode t with
                | By_value _ => true
                | By_reference => false
                | By_copy => false
                | By_nothing => false
                end)
               (fun (la : bool) (t : type) (n : Z) (a0 : attr) =>
                (hardware_alignof ha_env (Tarray t n a0) <=? alignof cenv (Tarray t n a0)) && la)
               (fun (la : bool) (id : ident) (a0 : attr) =>
                (hardware_alignof ha_env (Tstruct id a0) <=? alignof cenv (Tstruct id a0)) && la)
               (fun (la : bool) (id : ident) (a0 : attr) =>
                (hardware_alignof ha_env (Tunion id a0) <=? alignof cenv (Tunion id a0)) && la) T t0)) (co_members co)) =
      legal_alignas_composite cenv ha_env T (co_members co).
Proof.
  intros; unfold legal_alignas_composite, legal_alignas_type.
  induction (co_members co) as [| [i t] ?].
  + auto.
  + simpl.
    f_equal; auto.
    clear.
    induction t; auto.
    - simpl.
      rewrite IHt.
      auto.
    - simpl.
      destruct (T ! i); auto.
    - simpl.
      destruct (T ! i); auto.
Qed.

Lemma aux2: forall cenv ha_env,
    (type_func.Env
          (fun t : type =>
           (hardware_alignof ha_env t <=? alignof cenv t) &&
           match access_mode t with
           | By_value _ => true
           | By_reference => false
           | By_copy => false
           | By_nothing => false
           end)
          (fun (la : bool) (t : type) (n : Z) (a0 : attr) =>
           (hardware_alignof ha_env (Tarray t n a0) <=? alignof cenv (Tarray t n a0)) && la)
          (fun (la : bool) (id : ident) (a0 : attr) =>
           (hardware_alignof ha_env (Tstruct id a0) <=? alignof cenv (Tstruct id a0)) && la)
          (fun (la : bool) (id : ident) (a0 : attr) =>
           (hardware_alignof ha_env (Tunion id a0) <=? alignof cenv (Tunion id a0)) && la)
          (fun _ : struct_or_union =>
           fix fm (l : list (ident * type * bool)) : bool :=
             match l with
             | nil => true
             | (_, _, la) :: l' => la && fm l'
             end) (composite_reorder.rebuild_composite_elements cenv)) =
    legal_alignas_env cenv ha_env.
Proof.
  intros.
  unfold type_func.Env, type_func.env_rec, legal_alignas_env.
  f_equal.
  extensionality ic.
  destruct ic as [i co].
  extensionality T.
  f_equal.
  apply aux1.
Qed.

Theorem legal_alignas_env_consistency:
  forall (cenv: composite_env) (ha_env: PTree.t Z) (la_env: PTree.t bool),
    composite_env_consistent cenv ->
    legal_alignas_env_consistent cenv ha_env (legal_alignas_env cenv ha_env).
Proof.
  intros.
  pose proof @composite_reorder_consistent bool cenv
             (fun t => (hardware_alignof ha_env t <=? alignof cenv t) &&
                match access_mode t with
                | By_value _ => true
                | _ => false
                end)
             (fun la t n a => (hardware_alignof ha_env (Tarray t n a) <=? alignof cenv (Tarray t n a)) && la)
             (fun la id a => (hardware_alignof ha_env (Tstruct id a) <=? alignof cenv (Tstruct id a)) && la)
             (fun la id a => (hardware_alignof ha_env (Tunion id a) <=? alignof cenv (Tunion id a)) && la)
             (fun _ =>
                fix fm (l: list (ident * type * bool)): bool :=
                match l with
                | nil => true
                | (_, _, la) :: l' => la && (fm l')
                end)
             H
    as HH.
  hnf in HH.
  rewrite aux2 in HH.
  hnf; intros.
  specialize (HH _ _ la H0 H1).
  rewrite HH, aux1; auto.
Qed.

Theorem legal_alignas_env_completeness:
  forall (cenv: composite_env) (ha_env: PTree.t Z) (la_env: PTree.t bool),
    legal_alignas_env_complete cenv (legal_alignas_env cenv ha_env).
Proof.
  intros.
  pose proof @composite_reorder_complete bool cenv
             (fun t => (hardware_alignof ha_env t <=? alignof cenv t) &&
                match access_mode t with
                | By_value _ => true
                | _ => false
                end)
             (fun la t n a => (hardware_alignof ha_env (Tarray t n a) <=? alignof cenv (Tarray t n a)) && la)
             (fun la id a => (hardware_alignof ha_env (Tstruct id a) <=? alignof cenv (Tstruct id a)) && la)
             (fun la id a => (hardware_alignof ha_env (Tunion id a) <=? alignof cenv (Tunion id a)) && la)
             (fun _ =>
                fix fm (l: list (ident * type * bool)): bool :=
                match l with
                | nil => true
                | (_, _, la) :: l' => la && (fm l')
                end)
    as HH.
  hnf in HH.
  rewrite aux2 in HH.
  auto.
Qed.

Lemma two_power_nat_0: forall x, (exists n, x = two_power_nat n) -> x <> 0.
Proof.
  intros.
  destruct H.
  pose proof two_power_nat_pos x0.
  omega.
Qed.  

Hint Rewrite andb_true_iff: align.
Hint Rewrite <- Zle_is_le_bool: align.
Hint Rewrite Z.eqb_eq: align.
Hint Rewrite power_nat_divide_le using (auto with align): align.
Hint Rewrite Z.mod_divide using (apply two_power_nat_0; auto with align): align.
Hint Resolve alignof_two_p: align.
Hint Resolve align_chunk_two_p: align.
Hint Extern 10 (exists n: nat, hardware_alignof _ _ = two_power_nat n) => (eapply hardware_alignof_two_p; eassumption): align.

Lemma legal_alignas_type_divide: forall t,
  legal_alignas_type cenv ha_env la_env t = true ->
    (hardware_alignof ha_env t <=? alignof cenv t).

Lemma by_value_sound:
  forall (cenv: composite_env) (ha_env: PTree.t Z) (la_env: PTree.t bool) t ofs,
    is_aligned (legal_alignas_type cenv ha_env la_env t) (hardware_alignof ha_env t) ofs = true ->
    (exists ch, access_mode t = By_value ch) ->
    align_compatible_rec cenv t ofs.
Proof.
  intros.
  unfold is_aligned, legal_alignas_type, hardware_alignof in H.
  destruct H0 as [ch ?].
  assert ((align_chunk ch <=? alignof cenv t) && true && (ofs mod align_chunk ch =? 0) = true) by
    (destruct t; try solve [inversion H0]; rewrite H0 in H; auto); clear H.
  autorewrite with align in H1.
  destruct H1 as [_ ?].
  eapply align_compatible_rec_by_value; eauto.
Qed.

Theorem legal_alignas_soundness:
  forall (cenv: composite_env) (ha_env: PTree.t Z) (la_env: PTree.t bool),
    composite_env_consistent cenv ->
    hardware_alignof_env_consistent cenv ha_env ->
    hardware_alignof_env_complete cenv ha_env ->
    legal_alignas_env_consistent cenv ha_env la_env ->
    legal_alignas_env_complete cenv la_env ->
    legal_alignas_env_sound cenv ha_env la_env.
Proof.
  intros.
  hnf; intros.
  revert ofs H4; type_induction t cenv H; intros.
  + inversion H4.
  + eapply by_value_sound; eauto.
    destruct i, s; eexists; try reflexivity.
  + eapply by_value_sound; eauto.
    destruct s; eexists; try reflexivity.
  + eapply by_value_sound; eauto.
    destruct f; eexists; try reflexivity.
  + eapply by_value_sound; eauto.
    eexists; try reflexivity.
  + apply align_compatible_rec_Tarray; intros.
    apply IH; clear IH.
    unfold is_aligned in H4 |- *.
    Opaque alignof. simpl in H4 |- *. Transparent alignof.
    autorewrite with align in H4 |- *.
    destruct H4 as [[? ?] ?].
    split; auto.
    apply Z.divide_add_r; auto.
    apply Z.divide_mul_l.
    unfold legal_alignas_type in H6.
    autorewrite with align in H6.
    
    SearchAbout (_ | _ * _).
    rewrite Z.eqb_eq in H5 |- *.
    Check   power_nat_divide'.
    SearchAbout two_power_nat.
    Locate  two_power_nat_correct.
    apply Zmod_divide; auto.





















Lemma plain_alignof_spec: forall env t,
  alignof env t = align_attr (attr_of_type t) (plain_alignof env t).
Proof.
  intros.
  destruct t; auto.
Qed.

Definition local_legal_alignas_type env (t: type): bool :=
  Z.leb (plain_alignof env t) (alignof env t) &&
  match t with
  | Tarray t' n a => Z.eqb ((sizeof env t') mod (alignof env t')) 0 && Z.leb 0 n
  | Tlong _ _ => Z.leb 8 (alignof env t)
  | _ => true
  end.

Lemma local_legal_alignas_type_spec: forall env t,
  local_legal_alignas_type env t = true ->
  (plain_alignof env t | alignof env t).
Proof.
  intros.
  apply andb_true_iff in H.
  destruct H as [? _].
  apply Zle_is_le_bool in H.
  apply power_nat_divide'; [apply alignof_two_p | apply plain_alignof_two_p | omega].
Qed.

Lemma align_chunk_alignof: forall env t ch, local_legal_alignas_type env t = true -> access_mode t = By_value ch -> (Memdata.align_chunk ch | alignof env t).
Proof.
  intros.
  destruct t; inversion H0.
  - eapply Z.divide_trans; [| apply local_legal_alignas_type_spec; auto].
    destruct i, s; inversion H2; simpl; unfold align_attr;
    destruct (attr_alignas a); reflexivity.
  - unfold local_legal_alignas_type in H.
    rewrite andb_true_iff in H; destruct H as [_ ?].
    apply Zge_is_le_bool in H.
    apply power_nat_divide' in H.
    * auto.
    * apply alignof_two_p.
    * exists 3%nat; auto.
  - eapply Z.divide_trans; [| apply local_legal_alignas_type_spec; auto].
    destruct f; inversion H2; simpl; unfold align_attr;
    destruct (attr_alignas a); reflexivity.
  - eapply Z.divide_trans; [| apply local_legal_alignas_type_spec; auto].
    inversion H2; simpl; unfold align_attr;
    destruct (attr_alignas a); reflexivity.
Qed.

Definition composite_legal_alignas (env : composite_env) (co : composite) : Prop :=
  (co_alignof co >= alignof_composite env (co_members co)).

Definition composite_env_legal_alignas env :=
  forall (id : positive) (co : composite),
    env ! id = Some co -> composite_legal_alignas env co.
