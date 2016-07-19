Require Import Coq.Strings.String.

Require Import compcert.lib.Integers.
Require Import compcert.common.AST.
Require Import compcert.cfrontend.Clight.
Require Import compcert.common.Globalenvs.
Require Import compcert.common.Memory.
Require Import compcert.common.Memdata.
Require Import compcert.common.Values.

Require Import msl.Coqlib2.
Require Import msl.eq_dec.
Require Import msl.seplog.
Require Import veric.initial_world.
Require Import veric.juicy_mem.
Require Import veric.juicy_mem_lemmas.
Require Import veric.semax_prog.
Require Import veric.compcert_rmaps.
Require Import veric.Clight_new.
Require Import veric.Clightnew_coop.
Require Import veric.semax.
Require Import veric.semax_ext.
Require Import veric.juicy_extspec.
Require Import veric.initial_world.
Require Import veric.juicy_extspec.
Require Import veric.tycontext.
Require Import veric.semax_ext.
Require Import veric.semax_ext_oracle.
Require Import veric.res_predicates.
Require Import sepcomp.semantics.
Require Import sepcomp.step_lemmas.
Require Import sepcomp.event_semantics.
Require Import concurrency.semax_conc.
Require Import concurrency.juicy_machine.
Require Import concurrency.concurrent_machine.
Require Import concurrency.scheduler.
Require Import concurrency.addressFiniteMap.
Require Import concurrency.permissions.
Require Import concurrency.JuicyMachineModule.

Set Bullet Behavior "Strict Subproofs".

Ltac eassert :=
  let mp := fresh "mp" in
  pose (mp := fun {goal Q : Type} (x : goal) (y : goal -> Q) => y x);
  eapply mp; clear mp.

Ltac espec H := specialize (H ltac:(solve [eauto])).

Open Scope string_scope.

(*! Instantiation of modules *)
Import THE_JUICY_MACHINE.
Import JSEM.
Module Machine :=THE_JUICY_MACHINE.JTP.
Definition schedule := SCH.schedule.

(*+ Description of the invariant *)

Definition cm_state := (Mem.mem * Clight.genv * (schedule * Machine.t))%type.

(*! Coherence between locks in dry/wet memories and lock pool *)

Definition islock_pred R r := exists sh sh' z, r = YES sh sh' (LK z) (SomeP nil (fun _ => R)).

Lemma islock_pred_join_sub {r1 r2 R} : join_sub r1 r2 -> islock_pred R r1  -> islock_pred R r2.
Proof.
  intros [r0 J] [x [sh' [z ->]]].
  inversion J; subst; eexists; eauto.
Qed.

Inductive cohere_res_lock : forall (resv : option (option rmap)) (wetv : resource) (dryv : memval), Prop :=
| cohere_notlock wetv dryv:
    (forall sh sh' z P, wetv <> YES sh sh' (LK z) P) ->
    cohere_res_lock None wetv dryv
| cohere_locked R wetv :
    islock_pred R wetv ->
    cohere_res_lock (Some None) wetv (Byte (Integers.Byte.zero))
| cohere_unlocked R phi wetv :
    islock_pred R wetv ->
    R phi ->
    cohere_res_lock (Some (Some phi)) wetv (Byte (Integers.Byte.one)).

Definition LKspec_ext (R: pred rmap) : spec :=
   fun (rsh sh: Share.t) (l: AV.address)  =>
    allp (jam (adr_range_dec l lock_size)
                         (jam (eq_dec l) 
                            (yesat (SomeP nil (fun _ => R)) (LK lock_size) rsh sh)
                            (CTat l rsh sh))
                         (fun _ => TT)).

Definition LK_at R sh :=
  LKspec_ext R (Share.unrel Share.Lsh sh) (Share.unrel Share.Rsh sh).

Definition load_at m loc := Mem.load Mint32 m (fst loc) (snd loc).

Definition lock_coherence (lset : AMap.t (option rmap)) (phi : rmap) (m : mem) : Prop :=
  forall loc : address,
    match AMap.find loc lset with
    
    (* not a lock *)
    | None =>
      forall sh sh' z P,
        phi @ loc <> YES sh sh' (LK z) P /\
        phi @ loc <> YES sh sh' (CT z) P
    
    (* locked lock *)
    | Some None =>
      load_at m loc = Some (Vint Int.zero) /\
      exists sh R, LK_at R sh loc phi
    
    (* unlocked lock *)
    | Some (Some lockphi) =>
      load_at m loc = Some (Vint Int.one) /\
      exists sh (R : mpred),
        LK_at R sh loc phi /\
        (app_pred R (age_by 1 lockphi) \/ level phi = O)
        (*/\
        match age1 lockphi with
        | Some p => app_pred R p
        | None => Logic.True
        end*)
    end.

(*! Joinability and coherence *)

Lemma mem_compatible_forget {tp m phi} :
  mem_compatible_with tp m phi -> mem_compatible tp m.
Proof. intros M; exists phi. apply M. Qed.

Definition jm_
  {tp m PHI i}
  (cnti : Machine.containsThread tp i)
  (mcompat : mem_compatible_with tp m PHI)
  : juicy_mem :=
  personal_mem cnti (mem_compatible_forget mcompat).

Lemma personal_mem_ext
  tp tp' m
  (compat : mem_compatible tp m)
  (compat' : mem_compatible tp' m)
  (same_threads_rmaps: forall i cnti cnti',
      @Machine.getThreadR i tp cnti =
      @Machine.getThreadR i tp' cnti')
  i
  (cnti : Machine.containsThread tp i)
  (cnti' : Machine.containsThread tp' i) :
    personal_mem cnti compat = personal_mem cnti' compat'.
Proof.
  unfold jm_ in *.
  unfold personal_mem in *; simpl. 
  apply juicy_mem_ext.
  - unfold juicyRestrict in *; simpl.
    apply permissions.restrPermMap_ext.
    intros b; repeat f_equal; auto.
  - unfold personal_mem in *. simpl. auto.
Qed.

(*! Invariant (= above properties + safety + uniqueness of Krun) *)

Definition threads_safety {Z} (Jspec : juicy_ext_spec Z) m ge tp PHI (mcompat : mem_compatible_with tp m PHI) n :=
  forall i (cnti : Machine.containsThread tp i) (ora : Z),
    match Machine.getThreadC cnti with
    | Krun q
    | Kblocked q
    | Kresume q _ => semax.jsafeN Jspec ge n ora q (jm_ cnti mcompat)
    | Kinit _ _ => Logic.True
    end.

Definition threads_wellformed tp :=
  forall i (cnti : Machine.containsThread tp i),
    match Machine.getThreadC cnti with
    | Krun q => Logic.True
    | Kblocked q => cl_at_external q <> None
    | Kresume q v => cl_at_external q <> None /\ v = Vundef
    | Kinit _ _ => Logic.True
    end.

Definition threads_unique_Krun tp sch :=
  (lt 1 tp.(ThreadPool.num_threads).(pos.n) -> forall i cnti q (ora : Z),
      @ThreadPool.getThreadC i tp cnti = Krun q ->
      exists sch', sch = i :: sch').

Definition matchfunspec (ge : genviron) Gamma : forall Phi, Prop :=
  (ALL b : block,
    (ALL fs : funspec,
      seplog.func_at' fs (b, 0%Z) -->
      (EX id : ident,
        !! (ge id = Some b) && !! (Gamma ! id = Some fs))))%pred.

Definition lock_coherence' tp PHI m (mcompat : mem_compatible_with tp m PHI) :=
  lock_coherence
    (ThreadPool.lset tp) PHI
    (restrPermMap
       (mem_compatible_locks_ltwritable
          (mem_compatible_forget mcompat))).

Inductive state_invariant {Z} (Jspec : juicy_ext_spec Z) Gamma (n : nat) : cm_state -> Prop :=
  | state_invariant_c
      (m : mem) (ge : genv) (sch : schedule) (tp : ThreadPool.t) (PHI : rmap)
      (* (lev : level PHI = n) TODO add this back later *)
      (gamma : matchfunspec (filter_genv ge) Gamma PHI)
      (mcompat : mem_compatible_with tp m PHI)
      (lock_coh : lock_coherence' tp PHI m mcompat)
      (safety : threads_safety Jspec m ge tp PHI mcompat n)
      (wellformed : threads_wellformed tp)
      (uniqkrun :  threads_unique_Krun tp sch)
    : state_invariant Jspec Gamma n (m, ge, (sch, tp)).

Lemma state_invariant_S {Z} (Jspec : juicy_ext_spec Z) Gamma n m ge sch tp :
  state_invariant Jspec Gamma (S n) (m, ge, (sch, tp)) ->
  state_invariant Jspec Gamma n (m, ge, (sch, (* age_tp_to n *) tp)).
Proof.
  intros INV.
  inversion INV as [m0 ge0 sch0 tp0 PHI (* lev *) gam mcompat lock_coh safety wellformed uniqkrun H0]; subst.
  apply state_invariant_c with PHI mcompat; auto.
  (* unshelve eapply state_invariant_c with (age_to n PHI) _; auto.
  - inversion mcompat as [A B C D E]; constructor.
    clear -lev A. *)
  intros i cnti ora; specialize (safety i cnti ora).
  destruct (ThreadPool.getThreadC cnti); auto; apply safe_downward1, safety.
Qed.

Lemma state_invariant_sch_irr {Z} (Jspec : juicy_ext_spec Z) Gamma n m ge i sch sch' tp :
  state_invariant Jspec Gamma n (m, ge, (i :: sch, tp)) ->
  state_invariant Jspec Gamma n (m, ge, (i :: sch', tp)).
Proof.
  intros INV.
  inversion INV as [m0 ge0 sch0 tp0 PHI gam mcompat lock_coh safety wellformed uniqkrun H0];
    subst m0 ge0 sch0 tp0.
  refine (state_invariant_c Jspec Gamma n m ge (i :: sch') tp PHI gam mcompat lock_coh safety wellformed _).
  clear -uniqkrun.
  intros H i0 cnti q ora H0.
  destruct (uniqkrun H i0 cnti q ora H0) as [sch'' E].
  injection E as <- <-.
  eauto.
Qed.

(*+ Initial state *)

Section Initial_State.
  Variables
    (CS : compspecs) (V : varspecs) (G : funspecs)
    (ext_link : string -> ident) (prog : program)
    (all_safe : semax_prog.semax_prog (Concurrent_Oracular_Espec CS ext_link) prog V G)
    (init_mem_not_none : Genv.init_mem prog <> None).
  
  Definition Jspec := @OK_spec (Concurrent_Oracular_Espec CS ext_link).
  
  Definition init_m : { m | Genv.init_mem prog = Some m } :=
    match Genv.init_mem prog as y return (y <> None -> {m : mem | y = Some m}) with
    | Some m => fun _ => exist _ m eq_refl
    | None => fun H => (fun Heq => False_rect _ (H Heq)) eq_refl
    end init_mem_not_none.
  
  Definition initial_state (n : nat) (sch : schedule) : cm_state :=
    (proj1_sig init_m,
     globalenv prog,
     (sch,
      let spr := semax_prog_rule
                   (Concurrent_Oracular_Espec CS ext_link) V G prog
                   (proj1_sig init_m) all_safe (proj2_sig init_m) in
      let q : corestate := projT1 (projT2 spr) in
      let jm : juicy_mem := proj1_sig (snd (projT2 (projT2 spr)) n) in
      ThreadPool.mk
        (pos.mkPos (le_n 1))
        (* (fun _ => Kresume q Vundef) *)
        (fun _ => Krun q)
        (fun _ => m_phi jm)
        (addressFiniteMap.AMap.empty _)
     )
    ).
  
  Lemma personal_mem_of_same_jm tp jm (mc : mem_compatible tp (m_dry jm)) i (cnti : ThreadPool.containsThread tp i) :
    (ThreadPool.getThreadR cnti = m_phi jm) ->
    m_dry (personal_mem cnti mc) = m_dry jm.
  Proof.
  Admitted.
  
  Lemma initial_invariant n sch : state_invariant Jspec (make_tycontext_s G) n (initial_state n sch).
  Proof.
    unfold initial_state.
    destruct init_m as [m Hm]; simpl proj1_sig; simpl proj2_sig.
    set (spr := semax_prog_rule (Concurrent_Oracular_Espec CS ext_link) V G prog m all_safe Hm).
    set (q := projT1 (projT2 spr)).
    set (jm := proj1_sig (snd (projT2 (projT2 spr)) n)).
    match goal with |- _ _ _ (_, (_, ?TP)) => set (tp := TP) end.
    
    (*! compatibility of memories *)
    assert (compat : mem_compatible_with tp m (m_phi jm)).
    {
      constructor.
      + apply AllJuice with (m_phi jm) None.
        * change (proj1_sig (snd (projT2 (projT2 spr)) n)) with jm.
          unfold join_threads.
          unfold getThreadsR.
          
          match goal with |- _ ?l _ => replace l with (m_phi jm :: nil) end; swap 1 2. {
            simpl.
            set (a := m_phi jm).
            match goal with |- context [m_phi ?jm] => set (b := m_phi jm) end.
            replace b with a by reflexivity. clear. clearbody a.
            unfold fintype.ord_enum, eqtype.insub, seq.iota in *.
            simpl.
            destruct ssrbool.idP as [F|F]. reflexivity. exfalso. auto.
          }
          exists (core (m_phi jm)). {
            split.
            - apply join_comm.
              apply core_unit.
            - apply core_identity.
          }
        
        * reflexivity.
        * constructor.
      + destruct (snd (projT2 (projT2 spr))) as [jm' [D H]]; unfold jm; clear jm; simpl.
        subst m.
        apply JuicyMachineLemmas.mem_cohere'_juicy_mem.
      + intros b ofs.
        match goal with |- context [ssrbool.isSome ?x] => destruct x as [ phi | ] eqn:Ephi end; swap 1 2.
        { unfold is_true. simpl. congruence. } intros _.
        unfold tp in Ephi; simpl in Ephi.
        discriminate.
      + intros loc sh psh P z L.
        destruct (snd (projT2 (projT2 spr))) as [jm' [D [H [A NL]]]]; unfold jm in *; clear jm; simpl in L |- *.
        pose proof (NL loc) as NL'.
        rewrite L in NL'.
        edestruct NL as [lk ct].
        destruct lk; eauto.
      + hnf.
        simpl.
        intros ? F.
        inversion F.
    } (* end of mcompat *)

    apply state_invariant_c with (PHI := m_phi jm) (mcompat := compat).
    
    - pose proof semax_prog_entry_point (Concurrent_Oracular_Espec CS ext_link) V G prog.
      unfold matchfunspec in *.
      simpl.
      intros b SPEC phi NECR FU.
      (* rewrite find_id_maketycontext_s. *)
      admit.
      (* we need to relate the [jm] given by [semax_prog_rule]  *)
    
    - (*! lock coherence (no locks at first) *)
      intros lock.
      rewrite threadPool.find_empty.
      intros sh sh' z P; split; unfold jm;
      match goal with
        |- context [proj1_sig ?x] => destruct x as (jm' & jmm & lev & S & nolocks)
      end; simpl.
      + apply nolocks.
      + apply nolocks.
    
    - (*! safety of the only thread *)
      intros i cnti ora.
      destruct (ThreadPool.getThreadC cnti) as [c|c|c v|v1 v2] eqn:Ec; try discriminate; [].
      destruct i as [ | [ | i ]]. 2: now inversion cnti. 2:now inversion cnti.
      (* the initial juicy has got to be the same as the one given in initial_mem *)
      assert (Ejm: jm = jm_ cnti compat).
      {
        apply juicy_mem_ext; swap 1 2.
        - reflexivity.
        - unfold jm_.
          symmetry.
          unfold jm.
          destruct spr as (b' & q' & Hb & JS); simpl proj1_sig in *; simpl proj2_sig in *.
          destruct (JS n) as (jm' & jmm & lev & S & notlock); simpl projT1 in *; simpl projT2 in *.
          subst m.
          rewrite personal_mem_of_same_jm; eauto.
      }
      subst jm. rewrite <-Ejm.
      simpl in Ec. replace c with q in * by congruence.
      destruct spr as (b' & q' & Hb & JS); simpl proj1_sig in *; simpl proj2_sig in *.
      destruct (JS n) as (jm' & jmm & lev & Safe & notlock); simpl projT1 in *; simpl projT2 in *.
      subst q.
      simpl proj1_sig in *; simpl proj2_sig in *. subst n.
      apply (Safe ora).
    
    - (* well-formedness *)
      intros i cnti.
      constructor.
      
    - (* only one thread running *)
      intros F; exfalso. simpl in F. omega.
  Admitted.
  
End Initial_State.

Lemma cl_step_decay ge c m c' m' : @cl_step ge c m c' m' -> @decay m m'.
Proof.
  intros step.
  induction step
    as [ ve te k m a1 a2 b ofs v2 v m' H H0 H1 H2 ASS | |
         ve te k m optid a al tyagrs tyres cc vf vargs f m'  ve' le' H H0 H1 H2 H3 H4 NRV ALLOC H6 
         | | | | | | | | | f ve te optexp optid k m v' m' ve' te'' k' H H0 FREE H2 H3 | | | ];
    try apply decay_refl || apply IHstep.
  
  - (* assign: no change in permission *)
    intros b' ofs'.
    split.
    + inversion ASS as [v0 chunk m'0 H3 BAD H5 H6 | b'0 ofs'0 bytes m'0 H3 H4 H5 H6 H7 BAD H9 H10]; subst.
      -- pose proof storev_valid_block_2 _ _ _ _ _ BAD b'. tauto.
      -- pose proof Mem.storebytes_valid_block_2 _ _ _ _ _ BAD b'. tauto.
    + intros V; right; intros kind.
      (* destruct m as [c acc nb max no def]. simpl in *. *)
      inversion ASS as [v0 chunk m'0 H3 STO H5 H6 | b'0 ofs'0 bytes m'0 H3 H4 H5 H6 H7 STO H9 H10]; subst.
      -- simpl in *.
         Transparent Mem.store.
         unfold Mem.store in *; simpl in *.
         destruct (Mem.valid_access_dec m chunk b (Int.unsigned ofs) Writable).
         2:discriminate.
         injection STO as <-. simpl.
         reflexivity.
      -- Transparent Mem.storebytes.
         unfold Mem.storebytes in *.
         destruct (Mem.range_perm_dec
                     m b (Int.unsigned ofs)
                     (Int.unsigned ofs + Z.of_nat (Datatypes.length bytes)) Cur Writable).
         2:discriminate.
         injection STO as <-. simpl.
         reflexivity.
  
  - (* internal call : allocations *)
    clear -ALLOC.
    induction ALLOC. now apply decay_refl.
    apply decay_trans with m1. 3:apply IHALLOC.
    
    + clear -H.
      Transparent Mem.alloc.
      unfold Mem.alloc in *.
      injection H as <- <-.
      intros b V.
      unfold Mem.valid_block in *. simpl.
      apply Coqlib.Plt_trans_succ, V.
      
    + clear -H.
      unfold Mem.alloc in *.
      injection H as E <-.
      intros b ofs.
      split.
      * intros N V.
        subst m1.
        simpl in *.
        rewrite PMap.gsspec.
        unfold Mem.valid_block in *; simpl in *.
        if_tac; subst; auto.
        -- if_tac; auto.
        -- destruct N.
           apply Coqlib.Plt_succ_inv in V.
           tauto.
      * intros V.
        right.
        intros k.
        subst.
        simpl.
        rewrite PMap.gsspec.
        if_tac.
        -- subst b. inversion V. rewrite Pos.compare_lt_iff in *. edestruct Pos.lt_irrefl; eauto.
        -- reflexivity.
  
  - (* return: free_list *)
    revert FREE; clear.
    generalize (blocks_of_env ge ve); intros l.
    revert m m'; induction l as [| [[b o] o'] l IHl]; intros m m'' E.
    + simpl. injection E as <- ; apply decay_refl.
    + simpl in E.
      destruct (Mem.free m b o o') as [m' |] eqn:F.
      2:discriminate.
      specialize (IHl _ _ E).
      Transparent Mem.free.
      unfold Mem.free in *.
      if_tac in F. rename H into G.
      2:discriminate.
      apply decay_trans with m'. 3:now apply IHl.
      * injection F as <-.
        intros.
        unfold Mem.unchecked_free, Mem.valid_block in *.
        simpl in *.
        assumption.
      
      * injection F as <-.
        clear -G.
        unfold Mem.unchecked_free in *.
        intros b' ofs; simpl. unfold Mem.valid_block; simpl.
        split.
        tauto.
        intros V.
        rewrite PMap.gsspec.
        if_tac; auto. subst b'.
        hnf in G.
        destruct (Coqlib.proj_sumbool (Coqlib.zle o ofs)&&Coqlib.proj_sumbool (Coqlib.zlt ofs o')) eqn:E.
        2: now auto.
        left. split; auto.
        destruct m as [co acc nb max noa def] eqn:Em; simpl in *.
        unfold Mem.perm in G; simpl in *.
        specialize (G ofs).
        cut (acc !! b ofs Cur = Some Freeable). {
          destruct k; auto.
          pose proof Mem.access_max m b ofs as M.
          subst m; simpl in M.
          intros A; rewrite A in M.
          destruct (acc !! b ofs Max) as [ [] | ]; inversion M; auto.
        }
        assert (R: (o <= ofs < o')%Z). {
          rewrite andb_true_iff in *. destruct E as [E F].
          apply Coqlib.proj_sumbool_true in E.
          apply Coqlib.proj_sumbool_true in F.
          auto.
        }
        espec G.
        destruct (acc !! b ofs Cur) as [ [] | ]; inversion G; auto.
Qed.

Lemma cl_step_unchanged_on ge c m c' m' b ofs :
  @cl_step ge c m c' m' ->
  Mem.valid_block m b ->
  ~ Mem.perm m b ofs Cur Writable ->
  Maps.ZMap.get ofs (Maps.PMap.get b (Mem.mem_contents m)) =
  Maps.ZMap.get ofs (Maps.PMap.get b (Mem.mem_contents m')).
Admitted.

Lemma join_resource_decay b phi1 phi1' phi2 phi3 :
  resource_decay b phi1 phi1' ->
  level phi1 = S (level phi1') ->
  sepalg.join phi1 phi2 phi3 ->
  exists phi3',
    sepalg.join phi1' phi2 phi3' /\
    resource_decay b phi3 phi3' /\
    level phi3 = S (level phi3').
Admitted.

Lemma join_all_resource_decay {tp m Phi} c' {phi' i} {cnti : ThreadPool.containsThread tp i}:
  resource_decay (Mem.nextblock m) (ThreadPool.getThreadR cnti) phi' /\
  level (ThreadPool.getThreadR cnti) = S (level phi') ->
  join_all tp Phi ->
  exists Phi',
    join_all (age_tp_to (level phi') (ThreadPool.updThread cnti c' phi')) Phi' /\
    resource_decay (Mem.nextblock m) Phi Phi' /\
    level Phi = S (level Phi')
.
Admitted.

Definition mem_cohere := mem_cohere'.
Lemma mem_cohere_step m c c' jm jm' Phi (X : rmap) ge :
  mem_cohere m Phi ->
  sepalg.join (m_phi jm) X Phi ->
  corestep (juicy_core_sem cl_core_sem) ge c jm c' jm' ->
  exists Phi',
    sepalg.join (m_phi jm') X Phi' /\
    mem_cohere (m_dry jm') Phi'.
Proof.
  intros MC J C.
  destruct C as [step [RD L]].
  destruct (join_resource_decay _ _ _ _ _ RD L J) as [Phi' [J' [RD' L']]].
  exists Phi'. split. apply J'.
  constructor.
  - intros sh rsh v loc pp AT.
    pose proof resource_at_join _ _ _ loc J as Jloc.
    pose proof resource_at_join _ _ _ loc J' as J'loc.
    rewrite AT in J'loc.
    inversion J'loc; subst.
    + (* all was in jm' *)
      destruct MC.
      (* specialize (cont_coh sh rsh v loc pp). *)
      admit.
    + (* all was in X *)
      rewrite <-H in Jloc.
      inversion Jloc; subst.
      * symmetry in H7.
        pose proof cont_coh MC _ H7.
        intuition.
        (* because the juice was NO, the dry hasn't changed *)
        admit.
      * (* same reasoning? *)
        admit.
    + (* joining of permissions, values don't change *)
      symmetry in H.
      destruct jm'.
      apply (JMcontents _ _ _ _ _ H).
  - admit.
  - admit.
  - admit.
Admitted.

Lemma resource_decay_LK {b phi phi' loc rsh sh n pp} :
  resource_decay b phi phi' ->
  phi @ loc = YES rsh sh (LK n) pp ->
  phi' @ loc = YES rsh sh (LK n) (preds_fmap (approx (level phi')) pp).
Proof.
  intros [L R] E.
  specialize (R loc).
  rewrite E in *.
  destruct R as [N [R|[R|[R|R]]]].
  - rewrite <- R.
    reflexivity.
  - destruct R as [sh' [v [v' [R H]]]]. simpl in R. congruence.
  - destruct R as [v [v' R]]. specialize (N ltac:(auto)). congruence.
  - destruct R as [v [pp' [R H]]]. congruence.
Qed.

Lemma resource_decay_CT {b phi phi' loc rsh sh n} :
  resource_decay b phi phi' ->
  phi @ loc = YES rsh sh (CT n) NoneP ->
  phi' @ loc = YES rsh sh (CT n) NoneP.
Proof.
  intros [L R] E.
  specialize (R loc).
  rewrite E in *.
  destruct R as [N [R|[R|[R|R]]]].
  - rewrite <- R.
    unfold resource_fmap in *; f_equal.
    apply preds_fmap_NoneP.
  - destruct R as [sh' [v [v' [R H]]]]. simpl in R. congruence.
  - destruct R as [v [v' R]]. specialize (N ltac:(auto)). congruence.
  - destruct R as [v [pp' [R H]]]. congruence.
Qed.

Lemma resource_decay_LK_inv {b phi phi' loc rsh sh n pp'} :
  resource_decay b phi phi' ->
  phi' @ loc = YES rsh sh (LK n) pp' ->
  exists pp,
    pp' = preds_fmap (approx (level phi')) pp /\
    phi @ loc = YES rsh sh (LK n) pp.
Proof.
  intros [L R] E.
  specialize (R loc).
  rewrite E in *.
  destruct R as [N [R|[R|[R|R]]]].
  - destruct (phi @ loc); simpl in R; try discriminate.
    eexists.
    injection R. intros; subst.
    split; reflexivity.
  - destruct R as [sh' [v [v' [R H]]]]; congruence.
  - destruct R as [v [v' R]]; congruence.
  - destruct R as [v [pp [R H]]]; congruence.
Qed.

Lemma resource_decay_identity {b phi phi' loc} :
  resource_decay b phi phi' ->
  (fst loc < b)%positive ->
  identity (phi @ loc) ->
  identity (phi' @ loc).
Proof.
  intros [lev RD] LT ID; specialize (RD loc).
  destruct RD as [N [RD|[RD|[RD|RD]]]].
  destruct (phi @ loc) as [t | t p k p0 | k p]; simpl in RD; try rewrite <- RD.
  - auto.
  - apply YES_not_identity in ID. tauto.
  - apply PURE_identity.
  - destruct RD as (? & sh & _ & E & _).
    destruct (phi @ loc); simpl in E; try discriminate.
    apply YES_not_identity in ID. tauto.
  - destruct RD. auto with *.
  - destruct RD as (? & ? & ? & ->).
    apply NO_identity.
Qed.

Lemma resource_decay_LK_at {b phi phi' R sh loc} :
  resource_decay b phi phi' ->
  (fst loc < b)%positive ->
  (LK_at R sh loc) phi ->
  (LK_at (approx (level phi) R) sh loc) phi'.
Proof.
  intros RD LT LKAT loc'.
  specialize (LKAT loc').
  destruct (adr_range_dec loc lock_size loc') as [range|notrange]; swap 1 2.
  - rewrite jam_false in *; auto.
  - rewrite jam_true in *; auto.
    destruct (eq_dec loc loc') as [<-|noteq].
    + rewrite jam_true in *; auto.
      destruct LKAT as [p E]; simpl in E.
      apply (resource_decay_LK RD) in E.
      eexists.
      hnf.
      rewrite E.
      reflexivity.
    + rewrite jam_false in *; auto.
      destruct LKAT as [p E]; simpl in E.
      eexists; simpl.
      apply (resource_decay_CT RD) in E.
      rewrite E.
      reflexivity.
Qed.

(* todo: maybe remove one of those lemmas *)

Lemma resource_decay_LK_at' {b phi phi' R sh loc} :
  resource_decay b phi phi' ->
  (fst loc < b)%positive ->
  (LK_at R sh loc) phi ->
  (LK_at (approx (level phi') R) sh loc) phi'.
Proof.
  intros RD LT LKAT loc'.
  specialize (LKAT loc').
  destruct (adr_range_dec loc lock_size loc') as [range|notrange]; swap 1 2.
  - rewrite jam_false in *; auto.
  - rewrite jam_true in *; auto.
    destruct (eq_dec loc loc') as [<-|noteq].
    + rewrite jam_true in *; auto.
      destruct LKAT as [p E]; simpl in E.
      apply (resource_decay_LK RD) in E.
      eexists.
      hnf.
      rewrite E.
      f_equal.
      simpl.
      rewrite <- compose_assoc.
      rewrite approx_oo_approx'. 2:apply RD.
      f_equal.
      extensionality.
      unfold "oo".
      change (approx (level phi')   (approx (level phi')  R))
      with  ((approx (level phi') oo approx (level phi')) R).
      rewrite approx_oo_approx.
      reflexivity.
    + rewrite jam_false in *; auto.
      destruct LKAT as [p E]; simpl in E.
      eexists; simpl.
      apply (resource_decay_CT RD) in E.
      rewrite E.
      reflexivity.
Qed.

Lemma resource_decay_PURE {b phi phi'} :
  resource_decay b phi phi' ->
  forall loc sh P,
    phi @ loc = PURE sh P ->
    phi' @ loc = PURE sh (preds_fmap (approx (level phi')) P).
Proof.
  intros [L RD] loc sh P PAT.
  specialize (RD loc).
  destruct RD as [N [RD|[RD|[RD|RD]]]].
  - rewrite PAT in RD; simpl in RD. rewrite RD; auto.
  - rewrite PAT in RD; simpl in RD. destruct RD as (?&?&?&?&?). congruence.
  - rewrite PAT in N. pose proof (N (proj1 RD)). congruence.
  - rewrite PAT in RD; simpl in RD. destruct RD as (?&?&?&?). congruence.
Qed.

Lemma resource_decay_PURE_inv {b phi phi'} :
  resource_decay b phi phi' ->
  forall loc sh P',
    phi' @ loc = PURE sh P' ->
    exists P,
      phi @ loc = PURE sh P /\
      P' = preds_fmap (approx (level phi')) P.
Proof.
  intros [L RD] loc sh P PAT.
  specialize (RD loc).
  destruct RD as [N [RD|[RD|[RD|RD]]]].
Admitted (* lazy todo *).

Lemma resource_decay_func_at' {b phi phi'} :
  resource_decay b phi phi' ->
  forall loc fs,
    seplog.func_at' fs loc phi ->
    seplog.func_at' fs loc phi'.
Proof.
  intros RD loc [f cc A P Q] [pp E]; simpl.
  rewrite (resource_decay_PURE RD _ _ _ E).
  eexists. reflexivity.
Qed.

Lemma resource_decay_func_at'_inv {b phi phi'} :
  resource_decay b phi phi' ->
  forall loc fs,
    seplog.func_at' fs loc phi' ->
    seplog.func_at' fs loc phi.
Proof.
  intros RD loc [f cc A P Q] [pp E]; simpl.
  destruct (resource_decay_PURE_inv RD _ _ _ E) as [pp' [Ephi E']].
  pose proof resource_at_approx phi loc as H.
  rewrite Ephi in H at 1. rewrite <-H.
  eexists. reflexivity.
Qed.

Lemma hereditary_func_at' loc fs :
  hereditary age (seplog.func_at' fs loc).
Proof.
  intros x y a; destruct fs as [f cc A P Q]; simpl.
  intros [pp E].
  destruct (proj1 (age1_PURE _ _ loc (FUN f cc) a)) as [pp' Ey]; eauto.
  pose proof resource_at_approx y loc as H.
  rewrite Ey in H at 1; simpl in H.
  rewrite <-H.
  exists pp'.
  reflexivity.
Qed.

Lemma anti_hereditary_func_at' loc fs :
  hereditary (fun x y => age y x) (seplog.func_at' fs loc).
Proof.
  intros x y a; destruct fs as [f cc A P Q]; simpl.
  intros [pp E].
  destruct (proj2 (age1_PURE _ _ loc (FUN f cc) a)) as [pp' Ey]; eauto.
  pose proof resource_at_approx y loc as H.
  rewrite Ey in H at 1; simpl in H.
  rewrite <-H.
  exists pp'.
  reflexivity.
Qed.

Lemma hereditary_necR {phi phi' : rmap} {P} :
  necR phi phi' ->
  hereditary age P ->
  P phi -> P phi'.
Proof.
  intros N H; induction N; auto.
  apply H; auto.
Qed.

Lemma anti_hereditary_necR {phi phi' : rmap} {P} :
  necR phi phi' ->
  hereditary (fun x y => age y x) P ->
  P phi' -> P phi.
Proof.
  intros N H; induction N; auto.
  apply H; auto.
Qed.

Lemma resource_decay_matchfunspec {b phi phi' g Gamma} :
  resource_decay b phi phi' ->
  matchfunspec g Gamma phi ->
  matchfunspec g Gamma phi'.
Proof.
  intros RD M.
  unfold matchfunspec in *.
  intros b0 fs psi' necr' FUN.
  specialize (M b0 fs phi ltac:(constructor 2)).
  apply (hereditary_necR necr').
  { clear.
    intros phi phi' A (id & hg & hgam); exists id; split; auto. }
  apply (anti_hereditary_necR necr') in FUN; swap 1 2.
  { intros x y a. apply anti_hereditary_func_at', a. }
  apply (resource_decay_func_at'_inv RD) in FUN.
  espec M.
  destruct M as (id & Hg & HGamma).
  exists id; split; auto.
Qed.

Definition resource_is_lock r := exists rsh sh n pp, r = YES rsh sh (LK n) pp.

Definition same_locks phi1 phi2 := 
  forall loc, resource_is_lock (phi1 @ loc) <-> resource_is_lock (phi2 @ loc).

Definition resource_is_lock_sized n r := exists rsh sh pp, r = YES rsh sh (LK n) pp.

Definition same_locks_sized phi1 phi2 := 
  forall loc n, resource_is_lock_sized n (phi1 @ loc) <-> resource_is_lock_sized n (phi2 @ loc).

Definition lockSet_block_bound lset b :=
  forall loc, isSome (AMap.find (elt:=option rmap) loc lset) -> (fst loc < b)%positive.

Lemma resource_decay_same_locks {b phi phi'} :
  resource_decay b phi phi' -> same_locks phi phi'.
Proof.
  intros R loc; split; intros (rsh & sh & n & pp & E).
  - repeat eexists. eapply resource_decay_LK in E; eauto.
  - destruct (resource_decay_LK_inv R E) as [pp' [E' ->]].
    repeat eexists.
Qed.

Lemma resource_decay_same_locks_sized {b phi phi'} :
  resource_decay b phi phi' -> same_locks_sized phi phi'.
Proof.
  intros R loc n; split; intros (rsh & sh & pp & E).
  - repeat eexists. eapply resource_decay_LK in E; eauto.
  - destruct (resource_decay_LK_inv R E) as [pp' [E' ->]].
    repeat eexists.
Qed.

Lemma same_locks_juicyLocks_in_lockSet phi phi' lset :
  same_locks phi phi' ->
  juicyLocks_in_lockSet lset phi ->
  juicyLocks_in_lockSet lset phi'.
Proof.
  intros SL IN loc sh psh P n E.
  destruct (SL loc) as [_ (rsh & sh' & n' & pp & E')].
  { rewrite E. repeat eexists. }
  apply (IN loc _ _ _ _ E').
Qed.

Lemma resource_decay_lockSet_in_juicyLocks b phi phi' lset :
  resource_decay b phi phi' ->
  lockSet_block_bound lset b ->
  lockSet_in_juicyLocks lset phi ->
  lockSet_in_juicyLocks lset phi'.
Proof.
  intros RD LB IN loc IT.
  destruct (IN _ IT) as (rsh & sh & pp & E).
  (* assert (SL : same_locks phi phi') by (eapply resource_decay_same_locks; eauto). *)
  assert (SL : same_locks_sized phi phi') by (eapply resource_decay_same_locks_sized; eauto).
  destruct (SL loc LKSIZE) as [(rsh' & sh' & pp' &  E') _].
  { rewrite E. exists rsh, sh, pp. reflexivity. }
  destruct RD as [L RD].
  destruct (RD loc) as [NN [R|[R|[[P [v R]]|R]]]].
  + rewrite E in R. simpl in R; rewrite <- R.
    eauto.
  + rewrite E in R. destruct R as (sh'' & v & v' & R & H). discriminate.
  + specialize (LB loc).
    cut (fst loc < b)%positive. now intro; exfalso; eauto.
    apply LB. destruct (AMap.find (elt:=option rmap) loc lset).
    * apply I.
    * inversion IT.
  + destruct R as (v & v' & R & N').
    rewrite E'.
    exists rsh', sh', pp'.
    eauto.
Qed.

Lemma lockSet_Writable_lockSet_block_bound m lset  :
  lockSet_Writable lset m ->
  lockSet_block_bound lset (Mem.nextblock m).
Proof.
  simpl; intros LW.
  intros (b, ofs) IN; simpl.
  specialize (LW b ofs).
  destruct (AMap.find (elt:=option rmap) (b, ofs) lset). 2:inversion IN.
  specialize (LW eq_refl).
  cut (~ ~ (b < Mem.nextblock m)%positive). zify. omega. intros L.
  specialize (LW ofs).
  assert (Intv.In ofs (ofs, (ofs + LKSIZE)%Z)).
  { split; simpl; unfold LKSIZE in *; simpl; omega. }
  espec LW.
  rewrite (Mem.nextblock_noaccess _ _ ofs Max L) in LW.
  inversion LW.
Qed.

Lemma app_pred_age {R} {phi phi' : rmap} :
  age phi phi' ->
  app_pred R phi ->
  app_pred R phi'.
Proof.
  destruct R as [R HR]; simpl.
  apply HR.
Qed.

Lemma ontheboard {Phi Phi' phi phi' l z sh sh'} (R : mpred) :
  level Phi = level phi ->
  age Phi Phi' ->
  age phi phi' ->
  app_pred R phi ->
  Phi  @ l = YES sh sh' (LK z) (SomeP nil (fun _ => R)) ->
  app_pred (approx (S (level phi')) R) phi' /\
  Phi' @ l = YES sh sh' (LK z) (SomeP nil (fun _ => approx (level Phi') R)).
Proof.
  intros L A Au SAT AT.
  pose proof (app_pred_age Au SAT) as SAT'.
  split.
  - split.
    + apply age_level in A; apply age_level in Au. omega.
    + apply SAT'.
  - apply (necR_YES _ Phi') in AT.
    + rewrite AT.
      reflexivity.
    + constructor. assumption.
Qed.

(* todo remove those lemmas (they'll be in msl/ageable *)
Lemma iter_iter n m {A} f (x : A) : Nat.iter n f (Nat.iter m f x) = Nat.iter (n + m) f x.
Proof.
  induction n; auto; simpl. rewrite IHn; auto.
Qed.

Lemma age_by_age_by n m  {A} `{agA : ageable A} (x : A) : age_by n (age_by m x) = age_by (n + m) x.
Proof.
  apply iter_iter.
Qed.

Lemma age_by_ind {A} `{agA : ageable A} (P : A -> Prop) : 
  (forall x y, age x y -> P x -> P y) ->
  forall x n, P x -> P (age_by n x).
Proof.
  intros IH x n.
  unfold age_by.
  induction n; intros Px.
  - auto.
  - simpl. unfold age1' at 1.
    destruct (age1 (Nat.iter n age1' x)) as [y|] eqn:Ey; auto.
    eapply IH; eauto.
Qed.

Lemma resource_decay_lock_coherence {b phi phi' lset m} :
  resource_decay b phi phi' ->
  lockSet_block_bound lset b ->
  (forall l p, AMap.find l lset = Some (Some p) -> level p = level phi) ->
  lock_coherence lset phi m ->
  lock_coherence (AMap.map (Coqlib.option_map (age_to (level phi'))) lset) phi' m.
Proof.
  intros rd BOUND SAMELEV LC loc; pose proof rd as rd'; destruct rd' as [L RD].
  specialize (LC loc).
  specialize (RD loc).
  rewrite AMap_find_map_option_map.
  destruct (AMap.find loc lset)
    as [[unlockedphi | ] | ] eqn:Efind;
    simpl option_map; cbv iota beta; swap 1 3.
  - intros sh sh' z pp.
    destruct RD as [NN [R|[R|[[P [v R]]|R]]]].
    + split; intros E; rewrite E in *;
        destruct (phi @ loc); try destruct k; simpl in R; try discriminate;
          [ refine (proj1 (LC _ _ _ _) _); eauto
          | refine (proj2 (LC _ _ _ _) _); eauto ].
    + destruct R as (sh'' & v & v' & E & E'). split; congruence.
    + split; congruence.
    + destruct R as (sh'' & v & v' & R). split; congruence.
  
  - assert (fst loc < b)%positive.
    { apply BOUND.
      rewrite Efind.
      constructor. }
    destruct LC as (dry & sh & R & lk); split; auto.
    eapply resource_decay_LK_at in lk; eauto.
  
  - assert (fst loc < b)%positive.
    { apply BOUND.
      rewrite Efind.
      constructor. }
    destruct LC as (dry & sh & R & lk & sat); split; auto.
    exists sh, (approx (level phi') R); split.
    + eapply resource_decay_LK_at' in lk; eauto.
    + match goal with |- ?a \/ ?b => cut (~b -> a) end.
      { destruct (level phi'); auto. } intros Nz.
      split.
      * rewrite level_age_by.
        rewrite level_age_to.
        -- omega.
        -- apply SAMELEV in Efind.
           eauto with *.
      * destruct sat as [sat | ?]; [ | omega ].
        unfold age_to.
        rewrite age_by_age_by.
        rewrite plus_comm.
        rewrite <-age_by_age_by.
        apply age_by_ind.
        { destruct R as [p h]. apply h. }
        apply sat.
Qed.

Lemma isSome_find_map addr f lset :
  ssrbool.isSome (AMap.find (elt:=option rmap) addr (AMap.map f lset)) = 
  ssrbool.isSome (AMap.find (elt:=option rmap) addr lset).
Proof.
  match goal with |- _ ?a = _ ?b => destruct a eqn:E; destruct b eqn:F end; try reflexivity.
  - apply AMap_find_map_inv in E; destruct E as [x []]; congruence.
  - rewrite (AMap_find_map _ _ _ o F) in E. discriminate.
Qed.

Lemma interval_adr_range b start length i :
  Intv.In i (start, start + length) <->
  adr_range (b, start) length (b, i).
Proof.
  compute; intuition.
Qed.

Import ThreadPool.
Import JuicyMachineLemmas.

Lemma join_all_age_updThread_level tp i (cnti : ThreadPool.containsThread tp i) c phi Phi :
  join_all (age_tp_to (level phi) (ThreadPool.updThread cnti c phi)) Phi ->
  level Phi = level phi.
Proof.
  intros J; symmetry.
  remember (level phi) as n.
  rewrite <- (level_age_to n phi). 2:omega.
  apply rmap_join_sub_eq_level.
  assert (cnti' : containsThread (updThread cnti c phi) i) by eauto with *.
  rewrite (JuicyMachineLemmas.cnt_age _ _ n) in cnti'.
  pose proof compatible_threadRes_sub cnti' J as H.
  unshelve erewrite <-getThreadR_age in H; eauto with *.
  rewrite gssThreadRes in H.
  apply H.
Qed.

Lemma join_all_level_lset tp Phi l phi :
  join_all tp Phi ->
  AMap.find l (lset tp) = SSome phi ->
  level phi = level Phi.
Proof.
  intros J F.
  apply rmap_join_sub_eq_level.
  eapply compatible_lockRes_sub; eauto.
Qed.

Lemma join_all_level_phi tp Phi i (cnti : containsThread tp i) phi :
  join_all tp Phi ->
  getThreadR cnti = phi ->
  level phi = level Phi.
Proof.
  intros J <-.
  apply rmap_join_sub_eq_level.
  eapply compatible_threadRes_sub; eauto.
Qed.

Section Simulation.
  Variables
    (CS : compspecs)
    (ext_link : string -> ident)
    (ext_link_inj : forall s1 s2, ext_link s1 = ext_link s2 -> s1 = s2).

  Definition Jspec' := (@OK_spec (Concurrent_Oracular_Espec CS ext_link)).
  
  Inductive state_step : cm_state -> cm_state -> Prop :=
  | state_step_empty_sched ge m jstate :
      state_step
        (m, ge, (nil, jstate))
        (m, ge, (nil, jstate))
  | state_step_c ge m m' sch sch' jstate jstate' :
      @JuicyMachine.machine_step ge sch nil jstate m sch' nil jstate' m' ->
      state_step
        (m, ge, (sch, jstate))
        (m', ge, (sch', jstate')).
  
  (* Preservation lemma for core steps *)  
  Lemma invariant_thread_step
        {Z} (Jspec : juicy_ext_spec Z) Gamma
        n m ge i sch tp Phi ci ci' jmi'
        (gam : matchfunspec (filter_genv ge) Gamma Phi)
        (compat : mem_compatible_with tp m Phi)
        (lock_bound : lockSet_block_bound (ThreadPool.lset tp) (Mem.nextblock m))
        (lock_coh : lock_coherence' tp Phi m compat)
        (safety : threads_safety Jspec' m ge tp Phi compat (S n))
        (wellformed : threads_wellformed tp)
        (unique : threads_unique_Krun tp (i :: sch))
        (cnti : ThreadPool.containsThread tp i)
        (stepi : corestep (juicy_core_sem cl_core_sem) ge ci (personal_mem cnti (mem_compatible_forget compat)) ci' jmi')
        (safei' : forall ora : OK_ty, jsafeN Jspec' ge n ora ci' jmi')
        (Eci : ThreadPool.getThreadC cnti = Krun ci)
        (tp' := ThreadPool.updThread cnti (Krun ci') (m_phi jmi') : ThreadPool.t)
        (tp'' := age_tp_to (level jmi') tp')
        (cm' := (m_dry jmi', ge, (i :: sch, tp'')) : mem * genv * (list NatTID.tid * ThreadPool.t)) :
    state_invariant Jspec Gamma n cm'.
  Proof.
    (* destruct stepi as [step decay]. *)
    (* destruct compat as [juice_join all_cohere loc_writable loc_set_ok]. *)
    destruct compat as [JJ AC LW LJ JL] eqn:Ecompat. simpl in *.
    rewrite <-Ecompat in *.
    
    destruct (compatible_threadRes_sub cnti JJ) as [EXT JEXT].
    destruct (join_all_resource_decay (Krun ci') (proj2 stepi) JJ) as [Phi' [J' [RD L]]].
    assert (JEXT' : sepalg.join (m_phi jmi') EXT Phi'). {
      clear -JEXT J' JJ compat.
      rewrite <- (JuicyMachineLemmas.compatible_getThreadR_m_phi cnti (mem_compatible_forget compat)) in *.
      pose proof compatible_threadRes_sub cnti JJ.
      admit. (* cancellativity? or just list results *)
    }
    
    assert (compat' : mem_compatible_with tp'' (m_dry jmi') Phi').
    {
      constructor.
      - (* join_all (proved in lemma) *)
        apply J'.
      - (* cohere *)
        simpl in *.
        erewrite <- JuicyMachineLemmas.compatible_getThreadR_m_phi in JEXT.
        destruct (mem_cohere_step
                    m _ _ _ _ Phi EXT _ (ltac:(auto))
                    (ltac:(eauto)) stepi) as [Phi'' [J'' MC]].
        assert (Phi'' = Phi') by (eapply join_eq; eauto). subst Phi''.
        apply MC.
      
      - (* lockSet_Writable *)
        simpl.
        clear -LW stepi lock_coh lock_bound.
        destruct stepi as [step _]; simpl in step.
        intros b ofs IN.
        rewrite isSome_find_map in IN.
        specialize (LW b ofs IN).
        intros ofs0 interval.

        (* the juicy memory don't help much because we care about Max
        here. There are several cases were no permission change, the
        only cases where they do are:
        (1) call_internal (alloc_variables m -> m1)
        (2) return (free_list m -> m')
        in the end, (1) cannot hurt because there is already
        something, but maybe things have returned?
         *)
        
        match goal with _ : cl_step _ _ ?m _ _ |- _ => set (mi := m) end.
        fold mi in step.
        (* state that the Cur [Nonempty] using the juice and the
             fact that this is a lock *)
        assert (CurN : (Mem.mem_access mi) !! b ofs0 Cur = Some Nonempty
                       \/ (Mem.mem_access mi) !! b ofs0 Cur = None).
        {
          pose proof juicyRestrictCurEq as H.
          unfold access_at in H.
          replace b with (fst (b, ofs0)) by reflexivity.
          replace ofs0 with (snd (b, ofs0)) by reflexivity.
          unfold mi.
          rewrite (H _ _  _ (b, ofs0)).
          cut (Mem.perm_order'' (Some Nonempty) (perm_of_res (ThreadPool.getThreadR cnti @ (b, ofs0)))). {
            destruct (perm_of_res (ThreadPool.getThreadR cnti @ (b,ofs0))) as [[]|]; simpl.
            all:intros po; inversion po; subst; eauto.
          }
          clear -compat IN interval lock_coh lock_bound.
          apply po_trans with (perm_of_res (Phi @ (b, ofs0))).
          - destruct compat.
            specialize (lock_coh (b, ofs)).
            assert (lk : exists (sh : Share.t) (R : pred rmap), (LK_at R sh (b, ofs)) Phi). {
              destruct (AMap.find (elt:=option rmap) (b, ofs) (ThreadPool.lset tp)) as [[lockphi|]|].
              - destruct lock_coh as [_ [sh [R [lk _]]]].
                now eexists _, _; apply lk.
              - destruct lock_coh as [_ [sh [R lk]]].
                now eexists _, _; apply lk.
              - discriminate.
            }
            destruct lk as (sh & R & lk).
            specialize (lk (b, ofs0)). simpl in lk.
            assert (adr_range (b, ofs) lock_size (b, ofs0))
              by apply interval_adr_range, interval.
            if_tac in lk; [ | tauto ].
            if_tac in lk.
            + injection H1 as <-.
              destruct lk as [p ->].
              simpl.
              constructor.
            + destruct lk as [p ->].
              simpl.
              constructor.
          - cut (join_sub (ThreadPool.getThreadR cnti @ (b, ofs0)) (Phi @ (b, ofs0))).
            + apply po_join_sub.
            + apply resource_at_join_sub.
              eapply compatible_threadRes_sub.
              apply compat.
        }
          
        apply cl_step_decay in step.
        pose proof step b ofs0 as D.
        assert (Emi: (Mem.mem_access mi) !! b ofs0 Max = (Mem.mem_access m) !! b ofs0 Max).
        {
          pose proof juicyRestrictMax (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs0).
          unfold max_access_at in *.
          simpl fst in H; simpl snd in H.
          rewrite H.
          reflexivity.
        }
        
        destruct (Maps.PMap.get b (Mem.mem_access m) ofs0 Max)
          as [ [ | | | ] | ] eqn:Emax;
          try solve [inversion LW].
        + (* Max = Freeable *)
          
          (* concluding using [decay] *)
          revert step CurN.
          clearbody mi.
          generalize (m_dry jmi'); intros mi'.
          clear -Emi. intros D [NE|NE].
          * replace ((Mem.mem_access mi') !! b ofs0 Max) with (Some Freeable). now constructor.
            symmetry.
            destruct (D b ofs0) as [A B].
            destruct (valid_block_dec mi b) as [v|n].
            -- espec B.
               destruct B as [B|B].
               ++ destruct (B Cur). congruence.
               ++ specialize (B Max). congruence.
            -- pose proof Mem.nextblock_noaccess mi b ofs0 Max n.
               congruence.
          * replace ((Mem.mem_access mi') !! b ofs0 Max) with (Some Freeable). now constructor.
            symmetry.
            destruct (D b ofs0) as [A B].
            destruct (valid_block_dec mi b) as [v|n].
            -- espec B.
               destruct B as [B|B].
               ++ destruct (B Cur); congruence.
               ++ specialize (B Max). congruence.
            -- pose proof Mem.nextblock_noaccess mi b ofs0 Max n.
               congruence.
        
        + (* Max = writable : must be writable after, because unchanged using "decay" *)
          assert (Same: (Mem.mem_access m) !! b ofs0 Max = (Mem.mem_access mi) !! b ofs0 Max) by congruence.
          revert step Emi Same.
          generalize (m_dry jmi').
          generalize (juicyRestrict (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti))).
          clear.
          intros m0 m1 D Emi Same.
          match goal with |- _ ?a ?b => cut (a = b) end.
          { intros ->; apply po_refl. }
          specialize (D b ofs0).
          destruct D as [A B].
          destruct (valid_block_dec mi b) as [v|n].
          * espec B.
            destruct B as [B|B].
            -- destruct (B Max); congruence.
            -- specialize (B Max). congruence.
          * pose proof Mem.nextblock_noaccess m b ofs0 Max n.
            congruence.
        
        + (* Max = Readable : impossible because Max >= Writable  *)
          espec LW.
          espec LW.
          rewrite Emax in LW.
          inversion LW.
        
        + (* Max = Nonempty : impossible because Max >= Writable  *)
          espec LW.
          espec LW.
          rewrite Emax in LW.
          inversion LW.
        
        + (* Max = none : impossible because Max >= Writable  *)
          espec LW.
          espec LW.
          rewrite Emax in LW.
          inversion LW.
      
      - (* juicyLocks_in_lockSet *)
        eapply same_locks_juicyLocks_in_lockSet.
        + eapply resource_decay_same_locks.
          apply RD.
        + simpl.
          clear -LJ.
          intros loc sh psh P z H.
          rewrite isSome_find_map.
          eapply LJ; eauto.
        
      - (* lockSet_in_juicyLocks *)
        eapply resource_decay_lockSet_in_juicyLocks.
        + eassumption.
        + simpl.
          apply lockSet_Writable_lockSet_block_bound.
          clear -LW.
          intros b ofs.
          rewrite isSome_find_map.
          apply LW.
        
        + clear -JL.
          unfold tp''.
          intros addr; simpl.
          rewrite isSome_find_map.
          apply JL.
    }
    (* end of proving mem_compatible_with *)
    
    (* now that mem_compatible_with is established, we move on to the
    invariant. *)
    
    (* getting the new global phi by replacing jmi with jmi' : possible
because resource_decay says the only new things are above nextblock.

One should update all other threadR too? Just aging?

lock_coherence : ok, but there is work to do: because locks are
unchanged (no write permission) and no new lock have been allocated
(hmm) nor freed.

safety: current thread: we have its safety already, but we want to
know it's the safety after taking the personal_mem.  We also have to
prove that the other threads are safe with their new, aged, rmap.

wellformed: ok

unique: ok *)
    
    (* inversion juice_join as [tp0 PhiT PhiL r JT JL J H2 H3]; subst; clear juice_join. *)
    
    apply state_invariant_c with (PHI := Phi') (mcompat := compat').
    - (* matchfunspecs *)
      eapply resource_decay_matchfunspec; eauto.
    
    - (* lock coherence: own rmap has changed, not clear how to prove it did not affect locks *)
      unfold lock_coherence', tp''; simpl lset.

      (* replacing level (m_phi jmi') with level Phi' ... *)
      assert (REW: level (m_phi jmi') = level Phi').
      { symmetry. eapply join_all_age_updThread_level; eauto. }
      cut (lock_coherence
            (AMap.map (option_map (age_to (level Phi'))) (lset tp)) Phi'
            (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat')))).
      { match goal with |- ?a -> ?b => cut (a = b) end. intros ->. auto.
        f_equal. f_equal. f_equal. f_equal. auto. }
      (* done replacing *)
      
      (* operations on the lset: nothing happened *)
      apply (resource_decay_lock_coherence RD).
      { auto. }
      { intros. eapply join_all_level_lset; eauto. }
      
      clear -lock_coh lock_bound stepi.
      
      (* what's important: lock values couldn't change during a corestep *)
      assert
        (SA' :
           forall loc,
             AMap.find (elt:=option rmap) loc (lset tp) <> None ->
             load_at (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat))) loc =
             load_at (restrPermMap (mem_compatible_locks_ltwritable (mem_compatible_forget compat'))) loc).
      {
        destruct stepi as [step RD].
        unfold cl_core_sem in *.
        simpl in step.
        pose proof cl_step_decay _ _ _ _ _ step as D.
        intros (b, ofs) islock.
        pose proof juicyRestrictMax (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs).
        pose proof juicyRestrictContents (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs).
        unfold load_at in *; simpl.
        set (W  := mem_compatible_locks_ltwritable (mem_compatible_forget compat )).
        set (W' := mem_compatible_locks_ltwritable (mem_compatible_forget compat')).
        pose proof restrPermMap_Cur W as RW.
        pose proof restrPermMap_Cur W' as RW'.
        pose proof restrPermMap_contents W as CW.
        pose proof restrPermMap_contents W' as CW'.
        Transparent Mem.load.
        unfold Mem.load in *.
        destruct (Mem.valid_access_dec (restrPermMap W) Mint32 b ofs Readable) as [r|n]; swap 1 2.
        { (* can't be not readable *)
          destruct n.
          unfold Mem.valid_access in *.
          split.
          - unfold Mem.range_perm in *.
            intros ofs0 range.
            unfold Mem.perm in *.
            pose proof restrPermMap_Cur W b ofs0 as R.
            unfold permission_at in *.
            rewrite R.
            erewrite lockSet_spec_2.
            + constructor.
            + eauto.
            + unfold lockRes in *.
              unfold lockGuts in *.
              unfold LocksAndResources.lock_info in *.
              destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp)); auto.
          - (* basic alignment *)
            unfold align_chunk in *.
            admit (* will be added to the invariant *).
        }
        
        destruct (Mem.valid_access_dec (restrPermMap W') Mint32 b ofs Readable) as [r'|n']; swap 1 2.
        { (* can't be not readable *)
          destruct n'.
          unfold Mem.valid_access in *.
          split.
          - unfold Mem.range_perm in *.
            intros ofs0 range.
            unfold Mem.perm in *.
            pose proof restrPermMap_Cur W' b ofs0 as R.
            unfold permission_at in *.
            rewrite R.
            erewrite lockSet_spec_2.
            + constructor.
            + eauto.
            + unfold lockRes in *.
              unfold lockGuts in *.
              unfold LocksAndResources.lock_info in *.
              destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp'')) eqn:E; auto.
              unfold tp'' in E; simpl in E.
              erewrite AMap_find_map_option_map in E.
              destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp)); auto.
              simpl in E; inversion E.
          - (* basic alignment *)
            unfold align_chunk in *.
            admit (* will be added to the invariant *).
        }
        
        f_equal.
        f_equal.
        apply Mem.getN_exten.
        intros ofs0 interval.
        eapply equal_f with (b, ofs0) in CW.
        eapply equal_f with (b, ofs0) in CW'.
        unfold contents_at in CW, CW'.
        simpl fst in CW, CW'.
        simpl snd in CW, CW'.
        rewrite CW, CW'.
        pose proof cl_step_unchanged_on _ _ _ _ _ b ofs0 step as REW.
        rewrite <- REW.
        - reflexivity.
        - unfold Mem.valid_block in *.
          simpl.
          apply (lock_bound (b, ofs)).
          destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp)). reflexivity. tauto.
        - pose proof juicyRestrictCurEq (acc_coh (thread_mem_compatible (mem_compatible_forget compat) cnti)) (b, ofs0) as h.
          unfold access_at in *.
          simpl fst in h; simpl snd in h.
          unfold Mem.perm in *.
          rewrite h.
          cut (Mem.perm_order'' (Some Nonempty) (perm_of_res (getThreadR cnti @ (b, ofs0)))).
          { destruct (perm_of_res (getThreadR cnti @ (b, ofs0))); intros A B.
            all: inversion A; subst; inversion B; subst. }
          apply po_trans with (perm_of_res (Phi @ (b, ofs0))); swap 1 2.
          + eapply po_join_sub.
            apply resource_at_join_sub.
            eapply compatible_threadRes_sub.
            apply compat.
          + clear -lock_coh islock interval.
            (* todo make lemma out of this *)
            specialize (lock_coh (b, ofs)).
            assert (lk : exists sh R, (LK_at R sh (b, ofs)) Phi). {
              destruct (AMap.find (elt:=option rmap) (b, ofs) (lset tp)) as [[|]|].
              - destruct lock_coh as [_ (? & ? & ? & ?)]; eauto.
              - destruct lock_coh as [_ (? & ? & ?)]; eauto.
              - tauto.
            }
            destruct lk as (R & sh & lk).
            specialize (lk (b, ofs0)).
            simpl in lk.
            assert (adr_range (b, ofs) lock_size (b, ofs0))
              by apply interval_adr_range, interval.
            if_tac in lk; [|tauto].
            if_tac in lk.
            * destruct lk as [pp ->]. simpl. constructor.
            * destruct lk as [pp ->]. simpl. constructor.
      }
      (* end of proof of: lock values couldn't change during a corestep *)
      
      unfold lock_coherence' in *.
      intros loc; specialize (lock_coh loc). specialize (SA' loc).
      destruct (AMap.find (elt:=option rmap) loc (lset tp)) as [[lockphi|]|].
      + destruct lock_coh as [COH ?]; split; [ | easy ].
        rewrite <-COH; rewrite SA'; auto.
        congruence.
      + destruct lock_coh as [COH ?]; split; [ | easy ].
        rewrite <-COH; rewrite SA'; auto.
        congruence.
      + easy.
    
    - (* safety *)
      intros i0 cnti0 ora.
      destruct (eq_dec i i0).
      + (* for this threadshould be ok, if (jm_ of new Phi) is indeed jm_i' *)
        admit.
      + (* for other threads: prove that their new personal_mem (with the new Phi'/m') still make them safe *)
        admit.
    - (* wellformedness *)
      intros i0 cnti0.
      destruct (eq_dec i i0) as [ <- | ii0].
      + unfold tp'.
        admit.
        (* rewrite ThreadPool.gssThreadCode. *)
        (* constructor. *)
      + unfold tp'.
        admit.
        (* rewrite (@ThreadPool.gsoThreadCode _ _ tp ii0 cnti cnti0). *)
        (* apply wellformed. *)
    - (* uniqueness *)
      intros notalone i0 cnti0' q ora Eci0.
      admit (* more important things first *).
  Admitted.
  
  Theorem progress Gamma n state :
    state_invariant Jspec' Gamma (S n) state ->
    exists state',
      state_step state state'.
  Proof.
    intros I.
    inversion I as [m ge sch tp Phi gam compat lock_coh safety wellformed unique E]. rewrite <-E in *.
    destruct sch as [ | i sch ].
    
    (* empty schedule: we loop in the same state *)
    {
      exists state. subst. constructor.
    }
    
    destruct (ssrnat.leq (S i) tp.(ThreadPool.num_threads).(pos.n)) eqn:Ei; swap 1 2.
    
    (* bad schedule *)
    {
      eexists.
      (* split. *)
      (* -  *)constructor.
        apply JuicyMachine.schedfail with i.
        + reflexivity.
        + unfold ThreadPool.containsThread.
          now rewrite Ei; auto.
        + constructor.
        + reflexivity.
    }
    
    (* the schedule selected one thread *)
    assert (cnti : ThreadPool.containsThread tp i) by apply Ei.
    remember (ThreadPool.getThreadC cnti) as ci eqn:Eci; symmetry in Eci.
    
    destruct ci as
        [ (* Krun *) ci
        | (* Kblocked *) ci
        | (* Kresume *) ci v
        | (* Kinit *) v1 v2 ].
    
    (* thread[i] is running *)
    {
      pose (jmi := personal_mem cnti (mem_compatible_forget compat)).
      (* pose (phii := m_phi jmi). *)
      (* pose (mi := m_dry jmi). *)
      
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      (* thread[i] is running and some internal step *)
      {
        (* get the next step of this particular thread (with safety for all oracles) *)
        assert (next: exists ci' jmi',
                   corestep (juicy_core_sem cl_core_sem) ge ci jmi ci' jmi'
                   /\ forall ora, jsafeN Jspec' ge n ora ci' jmi').
        {
          specialize (safety i cnti).
          pose proof (safety nil) as safei.
          rewrite Eci in *.
          inversion safei as [ | ? ? ? ? c' m' step safe H H2 H3 H4 | | ]; subst.
          2: now match goal with H : at_external _ _ = _ |- _ => inversion H end.
          2: now match goal with H : halted _ _ = _ |- _ => inversion H end.
          exists c', m'. split; [ apply step | ].
          revert step safety safe; clear.
          generalize (jm_ cnti compat).
          generalize (State ve te k).
          unfold jsafeN.
          intros c j step safety safe ora.
          eapply safe_corestep_forward.
          - apply juicy_core_sem_preserves_corestep_fun.
            apply semax_lemmas.cl_corestep_fun'.
          - apply step.
          - apply safety.
        }
        
        destruct next as (ci' & jmi' & stepi & safei').
        pose (tp' := @ThreadPool.updThread i tp cnti (Krun ci') (m_phi jmi')).
        pose (tp'' := age_tp_to (level jmi') tp').
        pose (cm' := (m_dry jmi', ge, (i :: sch, tp''))).
        exists cm'.
        apply state_step_c; [].
        apply JuicyMachine.thread_step with
        (tid := i)
          (ev := nil)
          (Htid := cnti)
          (Hcmpt := mem_compatible_forget compat); [|]. reflexivity.
        eapply step_juicy; [ | | | | | ].
        + reflexivity.
        + now constructor.
        + exact Eci. 
        + destruct stepi as [stepi decay].
          split.
          * simpl.
            subst.
            unfold SEM.Sem in *.
            rewrite SEM.CLN_msem.
            apply stepi.
          * simpl.
            revert decay.
            match goal with |- ?P -> ?Q => cut (P = Q); [ now auto | ] end.
            reflexivity.
        + reflexivity.
        + reflexivity.
      }
      (* end of internal step *)
      
      (* thread[i] is running and about to call an external: Krun (at_ex c) -> Kblocked c *)
      {
        eexists.
        (* taking the step *)
        constructor.
        eapply JuicyMachine.suspend_step.
        + reflexivity.
        + reflexivity.
        + eapply mem_compatible_forget; eauto.
        + econstructor.
          * eassumption.
          * unfold SEM.Sem in *.
            rewrite SEM.CLN_msem.
            reflexivity.
          * constructor.
          * reflexivity.
      } (* end of Krun (at_ex c) -> Kblocked c *)
    } (* end of Krun *)
    
    (* thread[i] is in Kblocked *)
    {
      (* goes to Kresume ci' according to the rules of syncStep  *)
      
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      (* internal step: impossible, because in state Kblocked *)
      {
        exfalso.
        pose proof (wellformed i cnti) as W.
        rewrite Eci in W.
        apply W.
        reflexivity.
      }
      (* back to external step *)
      
      (* paragraph below: ef has to be an EF_external *)
      assert (Hef : match ef with EF_external _ _ => Logic.True | _ => False end).
      {
        pose proof (safety i cnti nil) as safe_i.
        rewrite Eci in safe_i.
        inversion safe_i; subst; [ now inversion H0; inversion H | | now inversion H ].
        inversion H0; subst; [].
        match goal with x : ext_spec_type _ _  |- _ => clear -x end.
        now destruct e eqn:Ee; [ apply I | .. ];
          simpl in x;
          repeat match goal with
                   _ : context [ oi_eq_dec ?x ?y ] |- _ =>
                   destruct (oi_eq_dec x y); try discriminate; try tauto
                 end.
      }
      assert (Ex : exists name sig, ef = EF_external name sig) by (destruct ef; eauto; tauto).
      destruct Ex as (name & sg & ->); clear Hef.
      
      (* paragraph below: ef has to be an EF_external with one of those 5 names *)
      assert (which_primitive :
                Some (ext_link "acquire") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "release") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "makelock") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "freelock") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "spawn") = (ef_id ext_link (EF_external name sg))).
      {
        pose proof (safety i cnti nil) as safe_i.
        rewrite Eci in safe_i.
        inversion safe_i; subst; [ now inversion H0; inversion H | | now inversion H ].
        inversion H0; subst; [].
        match goal with H : ext_spec_type _ _  |- _ => clear -H end.
        simpl in *.
        repeat match goal with
                 _ : context [ oi_eq_dec ?x ?y ] |- _ =>
                 destruct (oi_eq_dec x y); try injection e; auto
               end.
        tauto.
      }
      
      (* Before going any further, one needs to provide the first
        rmap of the oracle.  Unfortunately, for that, we need to know
        whether we're in an "acquire" external call or not. In
        addition, in the case of an "acquire" we need to know the
        arguments of the function (address+mpred) so that we can
        provide the right rmap from the lock set.
        |
        Two solutions: either we use a dummy oracle to know those things (but
        ... we need the oracle before that (FIX the spec OR [A]), or we write
        it as a P\/~P and then we derive a contradiction (not sure we can do
        that). *)
      
      destruct which_primitive as
          [ H_acquire | [ H_release | [ H_makelock | [ H_freelock | H_spawn ] ] ] ].
      
      { (* the case of acquire *)
        
        (* using the safety to prepare the precondition *)
        pose proof (safety i cnti nil) as safei.
        rewrite Eci in safei.
        unfold jsafeN, juicy_safety.safeN in safei.
        inversion safei
          as [ | n0 z c m0 c' m' H0 H1 H H2 H3 H4
               | n0 z c m0 e sig0 args0 x at_ex Pre SafePost H H3 H4 H5
               | n0 z c m0 i0 H H0 H1 H2 H3 H4];
          [ now inversion H0; inversion H | subst | now inversion H ].
        subst.
        simpl in at_ex. injection at_ex as <- <- <- .
        hnf in x.
        revert x Pre SafePost.
        
        (* dependent destruction *)
        simpl (ext_spec_pre _); simpl (ext_spec_post _).
        unfold funspecOracle2pre, funspecOracle2post.
        unfold ext_spec_pre, ext_spec_post.
        Local Notation "{| 'JE_spec ... |}" := {| JE_spec := _; JE_pre_hered := _; JE_post_hered := _; JE_exit_hered := _ |}.
        destruct (oi_eq_dec (Some (ext_link "acquire")) (ef_id ext_link (EF_external name sg)))
          as [Eef | Eef];
          [ | now clear -Eef H_acquire; simpl in *; congruence ].
        
        intros (phix, ((((ok, oracle_x), vx), shx), Rx)) Pre. simpl in Pre.
        destruct Pre as (phi0 & phi1 & Join & Precond & HnecR).
        simpl (and _).
        intros Post.
        
        (* relate lset to val *)
        destruct Precond as [PREA [[PREB _] PREC]].
        hnf in PREB.
        assert (islock : exists b ofs, vx = Vptr b ofs /\ exists R, islock_pred R (phi0 @ (b, Int.unsigned ofs))). {
          unfold canon.SEPx in PREC.
          simpl in PREC.
          rewrite seplog.sepcon_emp in PREC.
          unfold lock_inv in PREC.
          destruct PREC as (b & ofs & Evx & lk).
          exists b, ofs. split. now apply Evx.
          specialize (lk (b, Int.unsigned ofs)).
          exists (approx (level phi0) (Interp Rx)).
          simpl in lk.
          if_tac in lk; swap 1 2. {
            exfalso.
            apply H.
            unfold adr_range in *.
            intuition.
            unfold res_predicates.lock_size.
            omega.
          }
          if_tac in lk; [ | tauto ].
          destruct lk as [p lk].
          rewrite lk.
          do 3 eexists.
          unfold compose.
          reflexivity.
        }
        
        assert (SUB : join_sub phi0 Phi). {
          apply join_sub_trans with  (ThreadPool.getThreadR cnti).
          - econstructor; eauto.
          - apply compatible_threadRes_sub; eauto.
            destruct compat; eauto.
        }
        destruct islock as [b [ofs [-> [R islock]]]].
        pose proof (resource_at_join_sub _ _ (b, Int.unsigned ofs) SUB) as SUB'.
        pose proof islock_pred_join_sub SUB' islock as isl.
        
        (* PLAN
           - DONE: integrate the oracle in the semax_conc definitions
           - DONE: sort out this dependent type problem
           - DONE: exploit jsafeN_ to figure out which possible cases
           - DONE: push the analysis through Krun/Kblocked/Kresume
           - DONE: figure a wait out of the ext_link problem (the LOCK
             should be a parameter of the whole thing)
           - TODO: change the lock_coherence invariants to talk about
             Mem.load instead of directly reading the values, since
             this will be abstracted
           - TODO: acquire-fail: still problems (see below)
           - TODO: acquire-success: the invariant guarantees that the
             rmap in the lockset satisfies the invariant.  We can give
             this rmap as a first step to the oracle.  We again have
             to recover the fact that all oracles after this step will
             be fine as well.  (Let's write simulation lemmas about
             this, probably)
           - TODO: spawning: it introduces a new Kinit, change
             invariant accordingly
           - TODO release: this time, the jsafeN_ will explain how to
             split the current rmap.
           - TODO all the other primitives
         *)
        
          
        (* next step depends on status of lock: *)
        pose proof (lock_coh (b, Int.unsigned ofs)) as lock_coh'.
        destruct (AMap.find (elt:=option rmap) (b, Int.unsigned ofs) (ThreadPool.lset tp))
          as [[unlockedphi|]|] eqn:Efind;
          swap 1 3.
        (* inversion lock_coh' as [wetv dryv notlock H H1 H2 | R0 wetv isl' Elockset Ewet Edry | R0 phi wetv isl' SAT_R_Phi Elockset Ewet Edry]. *)
        
        - (* None: that cannot be: there is no lock at that address *)
          exfalso.
          destruct isl as [x [? [? EPhi]]].
          rewrite EPhi in lock_coh'.
          eapply (proj1 (lock_coh' _ _ _ _)).
          reflexivity.
        
        - (* Some None: lock is locked, so [acquire] fails. *)
          destruct lock_coh' as [LOAD (sh' & R' & lk)].
          destruct isl as [sh [psh [z Ewetv]]].
          rewrite Ewetv in *.
          
          (* rewrite Eat in Ewetv. *)
          specialize (lk (b, Int.unsigned ofs)).
          rewrite jam_true in lk; swap 1 2.
          { hnf. unfold lock_size in *; split; auto; omega. }
          rewrite jam_true in lk; swap 1 2. now auto.
          
          (*
          injection Ewetv as -> -> -> Epr.
          apply inj_pair2 in Epr.
          assert (R0 = R). {
            assert (feq: forall A B (f g : A -> B), f = g ->
              forall x, f x = g x) by congruence.
            apply (feq _ _ _ _ Epr tt).
          }
          subst R0; clear Epr.
           *)
          unfold canon.SEPx in PREC.
          unfold fold_right in PREC.
          rewrite seplog.sepcon_emp in PREC.
          unfold lock_inv in PREC.
          destruct PREC as (b0 & ofs0 & EQ & LKSPEC).
          injection EQ as <- <-.
          exists (m, ge, (sch, tp))(* ; split *).
          + apply state_step_c.
            apply JuicyMachine.sync_step with
            (Htid := cnti)
              (Hcmpt := mem_compatible_forget compat)
              (ev := Events.failacq (b, Int.intval (* replace with unsigned? *) ofs));
              [ reflexivity (* schedPeek *)
              | reflexivity (* schedSkip *)
              | ].
            eapply step_acqfail with (Hcompatible := mem_compatible_forget compat).
            * constructor.
            * apply Eci.
            * simpl.
              unfold SEM.Sem in *.
              rewrite SEM.CLN_msem; simpl.
              repeat f_equal.
              -- simpl.
                 simpl in H_acquire.
                 injection H_acquire as Ee.
                 apply ext_link_inj in Ee.
                 auto.
              -- (* inversion safei; subst. *)
                 admit.
                 (* design decision:
                    - we can make 'safety' imply wellformedness of this signature
                    - or we can add wellformed as an hypothesis of the program *)
                 (* see with andrew: should safety require signatures
                 to be exactly something?  Maybe it should be in
                 ext_spec_type, it'd be easy, maybe. *)
              -- admit (* another sig! *).
              -- assert (L: length args = 1%nat) by admit.
                 (* TODO discuss with andrew for where to add this requirement *)
                 clear -PREB L.
                 unfold expr.eval_id in PREB.
                 unfold expr.force_val in PREB.
                 match goal with H : context [Map.get ?a ?b] |- _ => destruct (Map.get a b) eqn:E end.
                 subst v. 2: discriminate.
                 pose  (gx := (filter_genv (symb2genv (Genv.genv_symb ge)))). fold gx in E.
                 destruct args as [ | arg [ | ar args ]].
                 ++ now inversion E.
                 ++ inversion E. reflexivity.
                 ++ inversion E. f_equal.
                    inversion L.
            * reflexivity.
            * reflexivity.
            * rewrite JuicyMachineLemmas.compatible_getThreadR_m_phi.
              specialize (LKSPEC (b, Int.unsigned ofs)).
              simpl in LKSPEC.
              if_tac in LKSPEC; swap 1 2.
              { destruct H.
                unfold lock_size; simpl.
                split. reflexivity. omega. }
              if_tac in LKSPEC; [ | congruence ].
              destruct LKSPEC as (p & E).
              pose proof (resource_at_join _ _ _ (b, Int.unsigned ofs) Join) as J.
              rewrite E in J.
              {
                inversion J; subst.
                - symmetry.
                  unfold Int.unsigned in *.
                  rewrite <-H7.
                  replace z with LKSIZE.
                  unfold pack_res_inv.
                  f_equal.
                  + admit (* again z / LKSIZE *).
                  + admit (* evar dependencies *).
                  + f_equal. extensionality x. unfold "oo".
                    reflexivity.
                  + admit (* again z / LKSIZE *).
                - (* same work as above *)
                  admit.
              }
            * (* maybe we should write this in the invariant instead? *)
              rewrite <-LOAD.
              unfold load_at.
              Transparent Mem.load.
              unfold Mem.load.
              unfold restrPermMap at 5.
              simpl.
              if_tac; if_tac; try reflexivity.
              -- exfalso; clear -H H0.
                 (* can we have a lemma saying that? assuming what?
                    if we can't, that's pretty bad. *)
                 admit.
              -- exfalso; clear -H H0.
                 (* same in other direction *)
                 admit.
        
        - (* acquire succeeds *)
          destruct isl as [sh [psh [z Ewetv]]].
          destruct lock_coh' as [LOAD (sh' & R' & lk & sat)].
          rewrite Ewetv in *.
          
          unfold canon.SEPx in PREC.
          unfold fold_right in PREC.
          rewrite seplog.sepcon_emp in PREC.
          unfold lock_inv in PREC.
          destruct PREC as (b0 & ofs0 & EQ & LKSPEC).
          injection EQ as <- <-.
          
          (* rewrite Eat in Ewetv. *)
          specialize (lk (b, Int.unsigned ofs)).
          rewrite jam_true in lk; swap 1 2.
          { hnf. unfold lock_size in *; split; auto; omega. }
          rewrite jam_true in lk; swap 1 2. now auto.
          assert (level Phi = S n).
          { (* will be added to the invariant *) admit. }
          destruct sat as [sat | sat]; [ | omega ].
          
          (* destruct isl' as [sh' [psh' [z' Eat]]]. *)
          (*
          rewrite Eat in Ewetv.
          injection Ewetv as -> -> -> Epr.
          apply inj_pair2 in Epr.
          assert (R0 = R). {
            assert (feq: forall A B (f g : A -> B), f = g -> forall x, f x = g x) by congruence.
            apply (feq _ _ _ _ Epr tt).
          }
          subst R0; clear Epr.
           *)
          eexists (* TODO explicitely provide the state -- wait, how
          do I specify the non-join? is it thanks to Post? *).
          (* split. *)
          + (* taking the step *)
            eapply state_step_c.
            eapply JuicyMachine.sync_step; [ reflexivity | reflexivity | ].
            eapply step_acquire.
            * now auto.
            * eassumption.
            * simpl.
              unfold SEM.Sem in *.
              rewrite SEM.CLN_msem.
              simpl.
              repeat f_equal; [ | | | ].
              -- simpl in H_acquire.
                 injection H_acquire as Ee.
                 apply ext_link_inj in Ee.
                 rewrite <-Ee.
                 reflexivity.
              -- admit (* same problem above *).
              -- admit (* same problem above *).
              -- admit (* same problem above *).
            * reflexivity.
            * admit (* precondition? *).
            * reflexivity.
            * admit (* real stuff: load 1 *).
            * admit (* real stuff: store 0 *).
            * admit (* real stuff: lock is Some *).
            * admit (* real stuff: it joins *).
            * reflexivity.
            * reflexivity.
      }

      { (* the case of release *) admit. }
      
      { (* the case of makelock *) admit. }
      
      { (* the case of freelock *) admit. }
      
      { (* the case of spawn *) admit. }
    }
    (* end of Kblocked *)
    
    (* thread[i] is in Kresume *)
    {
      (* goes to Krun ci' with after_ex ci = ci'  *)
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      - (* contradiction: has to be an extcall *)
        specialize (wellformed i cnti).
        rewrite Eci in wellformed.
        simpl in wellformed.
        tauto.
      
      - (* extcall *)
        pose (ci':=
                match lid with
                | Some id => State ve (Maps.PTree.set id (Vint Int.zero) te) k
                | None => State ve te k
                end).
        exists (m, ge, (i :: sch, ThreadPool.updThreadC cnti (Krun ci')))(* ; split *).
        + (* taking the step Kresum->Krun *)
          constructor.
          apply JuicyMachine.resume_step with (tid := i) (Htid := cnti).
          * reflexivity.
          * eapply mem_compatible_forget. eauto.
          * unfold SEM.Sem in *.
            eapply JuicyMachine.ResumeThread with (c := ci) (c' := ci');
              try rewrite SEM.CLN_msem in *;
              simpl.
            -- subst.
               unfold SEM.Sem in *.
               rewrite SEM.CLN_msem in *; simpl.
               reflexivity.
            -- subst.
               unfold SEM.Sem in *.
               rewrite SEM.CLN_msem in *; simpl.
               destruct lid; reflexivity.
            -- rewrite Eci.
               subst ci.
               f_equal.
               specialize (wellformed i cnti).
               rewrite Eci in wellformed.
               simpl in wellformed.
               tauto.
            -- constructor.
            -- reflexivity.
    }
    (* end of Kresume *)
    
    (* thread[i] is in Kinit *)
    {
      eexists(* ; split *).
      - constructor.
        apply JuicyMachine.start_step with (tid := i) (Htid := cnti).
        + reflexivity.
        + eapply mem_compatible_forget. eauto.
        + eapply JuicyMachine.StartThread.
          * apply Eci.
          * simpl.
            (* WE SAID THAT THIS SHOULD NOT BE IN THE MACHINE? *) 
            (* Maybe this is impossible and I have to do all the spawn
               work by myself. *)
           admit.
          * constructor.
          * reflexivity.
    }
    (* end of Kinit *)
  Admitted.
  
  Theorem preservation Gamma n state state' :
    state_step state state' ->
    state_invariant Jspec' Gamma (S n) state ->
    state_invariant Jspec' Gamma n state'.
  Proof.
    intros STEP.
    inversion STEP as [ | ge m m' sch sch' tp tp' jmstep E E'];
      [ now apply state_invariant_S | ]; subst state state'; clear STEP.
    intros INV.
    inversion INV as [m0 ge0 sch0 tp0 Phi gam compat lock_coh safety wellformed unique E].
    subst m0 ge0 sch0 tp0.
    
    destruct sch as [ | i sch ].
    
    (* empty schedule: we loop in the same state *)
    {
      inversion jmstep; subst; try inversion HschedN.
      (* PRESERVATION :
      subst; split.
      - constructor.
      - apply state_invariant_c with (PHI := Phi) (mcompat := compat); auto; [].
        intros i cnti ora. simpl.
        specialize (safety i cnti ora); simpl in safety.
        destruct (ThreadPool.getThreadC cnti); auto.
        all: eapply safe_downward1; intuition.
       *)
    }
    
    destruct (ssrnat.leq (S i) tp.(ThreadPool.num_threads).(pos.n)) eqn:Ei; swap 1 2.
    
    (* bad schedule *)
    {
      inversion jmstep; subst; try inversion HschedN; subst tid;
        unfold ThreadPool.containsThread, is_true in *;
        try congruence.
      simpl.
      
      assert (i :: sch <> sch) by (clear; induction sch; congruence).
      inversion jmstep; subst; simpl in *; try tauto;
        unfold ThreadPool.containsThread, is_true in *;
        try congruence.
      apply state_invariant_c with (PHI := Phi) (mcompat := compat); auto.
      + intros i0 cnti0 ora.
        specialize (safety i0 cnti0 ora); simpl in safety.
        eassert.
        * eapply safety; eauto.
        * destruct (ThreadPool.getThreadC cnti0) as [c|c|c v|v1 v2] eqn:Ec; auto;
            intros Safe; try split; try eapply safe_downward1, Safe; intuition.
      + (* invariant about "only one Krun and it is scheduled": the
          bad schedule case is not possible *)
        intros H0 i0 cnti q ora H1.
        exfalso.
        specialize (unique H0 i0 cnti q ora H1).
        destruct unique as [sch' unique]; injection unique as <- <- .
        congruence.
    }
    
    (* the schedule selected one thread *)
    assert (cnti : ThreadPool.containsThread tp i) by apply Ei.
    remember (ThreadPool.getThreadC cnti) as ci eqn:Eci; symmetry in Eci.
    (* remember (ThreadPool.getThreadR cnti) as phi_i eqn:Ephi_i; symmetry in Ephi_i. *)
    
    destruct ci as
        [ (* Krun *) ci
        | (* Kblocked *) ci
        | (* Kresume *) ci v
        | (* Kinit *) v1 v2 ].
    
    (* thread[i] is running *)
    {
      pose (jmi := personal_mem cnti (mem_compatible_forget compat)).
      (* pose (phii := m_phi jmi). *)
      (* pose (mi := m_dry jmi). *)
      
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      (* thread[i] is running and some internal step *)
      {
        (* get the next step of this particular thread (with safety for all oracles) *)
        assert (next: exists ci' jmi',
                   corestep (juicy_core_sem cl_core_sem) ge ci jmi ci' jmi'
                   /\ forall ora, jsafeN Jspec' ge n ora ci' jmi').
        {
          specialize (safety i cnti).
          pose proof (safety nil) as safei.
          rewrite Eci in *.
          inversion safei as [ | ? ? ? ? c' m'' step safe H H2 H3 H4 | | ]; subst.
          2: now match goal with H : at_external _ _ = _ |- _ => inversion H end.
          2: now match goal with H : halted _ _ = _ |- _ => inversion H end.
          exists c', m''. split; [ apply step | ].
          revert step safety safe; clear.
          generalize (jm_ cnti compat).
          generalize (State ve te k).
          unfold jsafeN.
          intros c j step safety safe ora.
          eapply safe_corestep_forward.
          - apply juicy_core_sem_preserves_corestep_fun.
            apply semax_lemmas.cl_corestep_fun'.
          - apply step.
          - apply safety.
        }
        
        destruct next as (ci' & jmi' & stepi & safei').
        pose (tp'' := @ThreadPool.updThread i tp cnti (Krun ci') (m_phi jmi')).
        pose (tp''' := age_tp_to (level jmi') tp').
        pose (cm' := (m_dry jmi', ge, (i :: sch, tp'''))).
        
        (* now, the step that has been taken in jmstep must correspond
        to this cm' *)
        inversion jmstep; subst; try inversion HschedN; subst tid;
          unfold ThreadPool.containsThread, is_true in *;
          try congruence.
        
        assert (i :: sch <> sch) by (clear; induction sch; congruence).
        inversion jmstep; subst; simpl in *; try tauto;
          unfold ThreadPool.containsThread, is_true in *;
        try congruence.
      (*
        exists cm'.
        (* split. *)
        
        - apply state_step_c; [].
          apply JuicyMachine.thread_step with
          (tid := i)
            (Htid := cnti)
            (Hcmpt := mem_compatible_forget compat); [|]. reflexivity.
          eapply JuicyMachineShell_ClightSEM.step_juicy; [ | | | | | ].
          + reflexivity.
          + now constructor.
          + exact Eci. 
          + destruct stepi as [stepi decay].
            split.
            * simpl.
              subst.
              apply stepi.
            * simpl.
              revert decay.
              match goal with |- ?P -> ?Q => cut (P = Q); [ now auto | ] end.
              reflexivity.
          + reflexivity.
          + reflexivity.

(* PRESERVATION        
        - (* build the new PHI: the new jm_i' + the other things? *)
          eapply invariant_thread_step; subst; eauto.
*)
      }
      (* end of internal step *)
      
      (* thread[i] is running and about to call an external: Krun (at_ex c) -> Kblocked c *)
      {
        eexists(* ; split *).
        
        - (* taking the step *)
          constructor.
          eapply JuicyMachine.suspend_step.
          + reflexivity.
          + reflexivity.
          + eapply mem_compatible_forget; eauto.
          + econstructor.
            * eassumption.
            * reflexivity.
            * constructor.
            * reflexivity.

(* PRESERVATION
        - (* maintaining the invariant *)
          match goal with |- _ _ (_, _, (_, ?tp)) => set (tp' := tp) end.
          assert (compat' : mem_compatible_with tp' m Phi).
          {
            clear safety wellformed unique.
            destruct compat as [JA MC LW LC LJ].
            constructor; [ | | | | ].
            - destruct JA as [tp phithreads philocks Phi jointhreads joinlocks join].
              econstructor; eauto.
            - apply MC.
            - intros b o H.
              apply (LW b o H).
            (* - intros l sh psh P z H. *)
            (*   apply (LW l sh psh P z H). *)
            - apply LC.
            - apply LJ.
          }
          apply state_invariant_c with (PHI := Phi) (mcompat := compat').
          
          + (* lock coherence *)
            eauto.
          
          + (* safety (same, except one thing is Kblocked instead of Krun) *)
            intros i0 cnti0' ora.
            destruct (eq_dec i i0) as [ii0 | ii0].
            * subst i0.
              unfold tp'.
              rewrite ThreadPool.gssThreadCC.
              specialize (safety i cnti ora).
              rewrite Eci in safety.
              simpl.
              simpl in safety.
              apply safe_downward1.
              unfold jm_ in *.
              erewrite personal_mem_ext.
              -- apply safety.
              -- intros i0 cnti1 cnti'.
                 apply ThreadPool.gThreadCR.
            * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
              unfold tp'.
              rewrite <- (@ThreadPool.gsoThreadCC _ _ tp ii0 cnti cnti0).
              specialize (safety i0 cnti0 ora).
              clear -safety.
              destruct (@ThreadPool.getThreadC i0 tp cnti0).
              -- unfold jm_ in *.
                 erewrite personal_mem_ext.
                 ++ apply safe_downward1, safety.
                 ++ intros; apply ThreadPool.gThreadCR.
              -- unfold jm_ in *.
                 erewrite personal_mem_ext.
                 ++ apply safe_downward1, safety.
                 ++ intros; apply ThreadPool.gThreadCR.
              -- unfold jm_ in *.
                 erewrite personal_mem_ext.
                 ++ apply safe_downward1, safety.
                 ++ intros; apply ThreadPool.gThreadCR.
              -- constructor.
          
          + (* wellformed. *)
            intros i0 cnti0'.
            destruct (eq_dec i i0) as [ii0 | ii0].
            * subst i0.
              unfold tp'.
              rewrite ThreadPool.gssThreadCC.
              simpl.
              congruence.
            * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
              unfold tp'.
              rewrite <- (@ThreadPool.gsoThreadCC _ _ tp ii0 cnti cnti0).
              specialize (wellformed i0 cnti0).
              destruct (@ThreadPool.getThreadC i0 tp cnti0).
              -- constructor.
              -- apply wellformed.
              -- apply wellformed.
              -- constructor.
          
          + (* uniqueness *)
            intros notalone i0 cnti0' q ora Eci0.
            pose proof (unique notalone i0 cnti0' q ora) as unique'.
            destruct (eq_dec i i0) as [ii0 | ii0].
            * subst i0.
              unfold tp' in Eci0.
              rewrite ThreadPool.gssThreadCC in Eci0.
              discriminate.
            * assert (cnti0 : ThreadPool.containsThread tp i0) by auto.
              unfold tp' in Eci0.
              clear safety wellformed.
              rewrite <- (@ThreadPool.gsoThreadCC _ _ tp ii0 cnti cnti0) in Eci0.
              destruct (unique notalone i cnti _ ora Eci).
              destruct (unique notalone i0 cnti0 q ora Eci0).
              congruence.
*)

      } (* end of Krun (at_ex c) -> Kblocked c *)
    } (* end of Krun *)
    
    (* thread[i] is in Kblocked *)
    {
      (* goes to Kresume ci' according to the rules of syncStep  *)
      
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      (* internal step: impossible, because in state Kblocked *)
      {
        exfalso.
        pose proof (wellformed i cnti) as W.
        rewrite Eci in W.
        apply W.
        reflexivity.
      }
      (* back to external step *)
      
      (* paragraph below: ef has to be an EF_external *)
      assert (Hef : match ef with EF_external _ _ => Logic.True | _ => False end).
      {
        pose proof (safety i cnti nil) as safe_i.
        rewrite Eci in safe_i.
        inversion safe_i; subst; [ now inversion H0; inversion H | | now inversion H ].
        inversion H0; subst; [].
        match goal with x : ext_spec_type _ _  |- _ => clear -x end.
        now destruct e eqn:Ee; [ apply I | .. ];
          simpl in x;
          repeat match goal with
                   _ : context [ oi_eq_dec ?x ?y ] |- _ =>
                   destruct (oi_eq_dec x y); try discriminate; try tauto
                 end.
      }
      assert (Ex : exists name sig, ef = EF_external name sig) by (destruct ef; eauto; tauto).
      destruct Ex as (name & sg & ->); clear Hef.
      
      (* paragraph below: ef has to be an EF_external with one of those 5 names *)
      assert (which_primitive :
                Some (ext_link "acquire") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "release") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "makelock") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "freelock") = (ef_id ext_link (EF_external name sg)) \/
                Some (ext_link "spawn") = (ef_id ext_link (EF_external name sg))).
      {
        pose proof (safety i cnti nil) as safe_i.
        rewrite Eci in safe_i.
        inversion safe_i; subst; [ now inversion H0; inversion H | | now inversion H ].
        inversion H0; subst; [].
        match goal with H : ext_spec_type _ _  |- _ => clear -H end.
        simpl in *.
        repeat match goal with
                 _ : context [ oi_eq_dec ?x ?y ] |- _ =>
                 destruct (oi_eq_dec x y); try injection e; auto
               end.
        tauto.
      }
      
      (* Before going any further, one needs to provide the first
        rmap of the oracle.  Unfortunately, for that, we need to know
        whether we're in an "acquire" external call or not. In
        addition, in the case of an "acquire" we need to know the
        arguments of the function (address+mpred) so that we can
        provide the right rmap from the lock set.
        |
        Two solutions: either we use a dummy oracle to know those things (but
        ... we need the oracle before that (FIX the spec OR [A]), or we write
        it as a P\/~P and then we derive a contradiction (not sure we can do
        that). *)
      
      destruct which_primitive as
          [ H_acquire | [ H_release | [ H_makelock | [ H_freelock | H_spawn ] ] ] ].
      
      { (* the case of acquire *)
        
        (* using the safety to prepare the precondition *)
        pose proof (safety i cnti nil) as safei.
        rewrite Eci in safei.
        unfold jsafeN, juicy_safety.safeN in safei.
        inversion safei
          as [ | n0 z c m0 c' m' H0 H1 H H2 H3 H4
               | n0 z c m0 e sig0 args0 x at_ex Pre SafePost H H3 H4 H5
               | n0 z c m0 i0 H H0 H1 H2 H3 H4];
          [ now inversion H0; inversion H | subst | now inversion H ].
        subst.
        simpl in at_ex. injection at_ex as <- <- <- .
        hnf in x.
        revert x Pre SafePost.
        
        (* dependent destruction *)
        simpl (ext_spec_pre _); simpl (ext_spec_post _).
        unfold funspecOracle2pre, funspecOracle2post.
        unfold ext_spec_pre, ext_spec_post.
        Local Notation "{| 'JE_spec ... |}" := {| JE_spec := _; JE_pre_hered := _; JE_post_hered := _; JE_exit_hered := _ |}.
        destruct (oi_eq_dec (Some (ext_link "acquire")) (ef_id ext_link (EF_external name sg)))
          as [Eef | Eef];
          [ | now clear -Eef H_acquire; simpl in *; congruence ].
        
        intros (phix, ((((ok, oracle_x), vx), shx), Rx)) Pre. simpl in Pre.
        destruct Pre as (phi0 & phi1 & Join & Precond & HnecR).
        simpl (and _).
        intros Post.
        
        (* relate lset to val *)
        destruct Precond as [PREA [[PREB _] PREC]].
        hnf in PREB.
        assert (islock : exists b ofs, vx = Vptr b ofs /\ exists R, islock_pred R (phi0 @ (b, Int.unsigned ofs))). {
          unfold canon.SEPx in PREC.
          simpl in PREC.
          rewrite seplog.sepcon_emp in PREC.
          unfold lock_inv in PREC.
          destruct PREC as (b & ofs & Evx & lk).
          exists b, ofs. split. now apply Evx.
          specialize (lk (b, Int.unsigned ofs)).
          exists (approx (level phi0) (Interp Rx)).
          simpl in lk.
          if_tac in lk; swap 1 2. {
            exfalso.
            apply H.
            unfold adr_range in *.
            intuition.
            unfold res_predicates.lock_size.
            omega.
          }
          if_tac in lk; [ | tauto ].
          destruct lk as [p lk].
          rewrite lk.
          do 3 eexists.
          unfold compose.
          reflexivity.
        }
        
        assert (SUB : join_sub phi0 Phi). {
          apply join_sub_trans with  (ThreadPool.getThreadR cnti).
          - econstructor; eauto.
          - apply JuicyMachineLemmas.compatible_threadRes_sub; eauto.
            destruct compat; eauto.
        }
        destruct islock as [b [ofs [-> [R islock]]]].
        pose proof (resource_at_join_sub _ _ (b, Int.unsigned ofs) SUB) as SUB'.
        pose proof islock_pred_join_sub SUB' islock as isl.
        
        (* PLAN
           - DONE: integrate the oracle in the semax_conc definitions
           - DONE: sort out this dependent type problem
           - DONE: exploit jsafeN_ to figure out which possible cases
           - DONE: push the analysis through Krun/Kblocked/Kresume
           - DONE: figure a wait out of the ext_link problem (the LOCK
             should be a parameter of the whole thing)
           - TODO: change the lock_coherence invariants to talk about
             Mem.load instead of directly reading the values, since
             this will be abstracted
           - TODO: acquire-fail: still problems (see below)
           - TODO: acquire-success: the invariant guarantees that the
             rmap in the lockset satisfies the invariant.  We can give
             this rmap as a first step to the oracle.  We again have
             to recover the fact that all oracles after this step will
             be fine as well.  (Let's write simulation lemmas about
             this, probably)
           - TODO: spawning: it introduces a new Kinit, change
             invariant accordingly
           - TODO release: this time, the jsafeN_ will explain how to
             split the current rmap.
           - TODO all the other primitives
         *)
        
          
        (* next step depends on status of lock: *)
        pose proof (lock_coh (b, Int.unsigned ofs)) as lock_coh'.
        inversion lock_coh' as [wetv dryv notlock H H1 H2 | R0 wetv isl' Elockset Ewet Edry | R0 phi wetv isl' SAT_R_Phi Elockset Ewet Edry].
        
        - (* this is not even a lock *)
          exfalso.
          clear -isl notlock.
          destruct isl as [x [? [? ]]].
          eapply notlock.
          now eauto.
        
        - (* acquire fails *)
          destruct isl as [sh [psh [z Ewetv]]].
          subst wetv.
          destruct isl' as [sh' [psh' [z' Eat]]].
          rewrite Eat in Ewetv.
          injection Ewetv as -> -> -> Epr.
          apply inj_pair2 in Epr.
          assert (R0 = R). {
            assert (feq: forall A B (f g : A -> B), f = g -> forall x, f x = g x) by congruence.
            apply (feq _ _ _ _ Epr tt).
          }
          subst R0; clear Epr.
          exists (m, ge, (sch, tp))(* ; split *).
          + (* taking the step *)
            eapply state_step_c.
            eapply JuicyMachine.sync_step; [ reflexivity | reflexivity | ].
            eapply step_acqfail.
            * constructor.
            * apply Eci.
            * simpl.
              repeat f_equal.
              -- simpl in H_acquire.
                 injection H_acquire as Ee.
                 apply ext_link_inj in Ee.
                 rewrite <-Ee.
                 reflexivity.
              -- inversion safei; subst.
                 admit. 2:admit.
                 simpl in H0.
                 injection H0 as <- <- <-.
                 simpl in H1.
                 admit.
                 (* see with andrew: should safety require signatures
                 to be exactly something?  Maybe it should be in
                 ext_spec_type, it'd be easy, maybe. *)
              -- admit (* another sig! *).
              -- instantiate (2 := b).
                 instantiate (1 := ofs).
                 assert (L: length args = 1%nat) by admit. (* TODO discuss with andrew for where to add this requirement *)
                 clear -PREB L.
                 unfold expr.eval_id in PREB.
                 unfold expr.force_val in PREB.
                 match goal with H : context [Map.get ?a ?b] |- _ => destruct (Map.get a b) eqn:E end.
                 subst v. 2: discriminate.
                 pose  (gx := (filter_genv (symb2genv (Genv.genv_symb ge)))). fold gx in E.
                 destruct args as [ | arg [ | ar args ]].
                 ++ now inversion E.
                 ++ inversion E. reflexivity.
                 ++ inversion E. f_equal.
                    inversion L.
            * reflexivity.
            * reflexivity.
            * rewrite JuicyMachineLemmas.compatible_getThreadR_m_phi.
              unfold pack_res_inv in *.
              (*
              etransitivity. admit.
              etransitivity. apply Eat.
              f_equal.*)
              (* destruct args. *)
              admit (* LKSIZE problem + joinsub things *).
            * (* maybe we should write this in the invariant instead? *)
              admit.
(* PRESERVATION
          + (* invariant (easy, same state than before) *)
            apply state_invariant_c with (PHI := Phi) (mcompat := compat).
            * eauto.
            * intros i0 cnti0 ora.
              specialize (safety i0 cnti0 ora).
              destruct (ThreadPool.getThreadC cnti0); try apply safe_downward1; auto.
            * eauto.
            * (* uniqueness (if there is a Krun, then it would have
              been schedule, but the scheduled thread was a Kblocked,
              so no problem *)
              admit (* more important things now *).
*)
        
        - (* acquire succeeds *)
          destruct isl as [sh [psh [z Ewetv]]].
          destruct isl' as [sh' [psh' [z' Eat]]].
          rewrite Eat in Ewetv.
          injection Ewetv as -> -> -> Epr.
          apply inj_pair2 in Epr.
          assert (R0 = R). {
            assert (feq: forall A B (f g : A -> B), f = g -> forall x, f x = g x) by congruence.
            apply (feq _ _ _ _ Epr tt).
          }
          subst R0; clear Epr.
          eexists (* TODO explicitely provide the state -- wait, how
          do I specify the non-join? is it thanks to Post? *).
          (* split. *)
          + (* taking the step *)
            eapply state_step_c.
            eapply JuicyMachine.sync_step; [ reflexivity | reflexivity | ].
            eapply step_acquire.
            * now auto.
            * eassumption.
            * simpl.
              repeat f_equal; [ | | | ].
              -- simpl in H_acquire.
                 injection H_acquire as Ee.
                 apply ext_link_inj in Ee.
                 rewrite <-Ee.
                 reflexivity.
              -- admit (* same problem above *).
              -- admit (* same problem above *).
              -- admit (* same problem above *).
            * reflexivity.
            * admit (* precondition? *).
            * reflexivity.
            * admit (* real stuff: load 1 *).
            * admit (* real stuff: store 0 *).
            * admit (* real stuff: lock is Some *).
            * admit (* real stuff: it joins *).
            * reflexivity.
            * reflexivity.

(* PRESERVATION 
          + (* invariant is maintainted (should be the same global rmap) *)
            (*
            assert (
                mem_compatible_with
                  (ThreadPool.updLockSet
                     (ThreadPool.updThread
                        cnti
                        (Kresume (ExtCall (EF_external name sg) sig args lid ve te k) Vundef)
                        (m_phi ?jm')) (?b0, Int.intval ?ofs0) None)
                  (m_dry ?jm')).
             *)
            eapply state_invariant_c with (PHI := Phi) (mcompat := _).
            * (* TODO lock_coherence (hard) some work needed here *)
              admit.
            * (* TODO safety (hard) a lot of work needed here, using the oracle. *)
              admit.
            * (* wellformedness (symbol pushing) *)
              admit.
            * (* uniqueness (symbol pushing) *)
              admit.
 *)
      }

      { (* the case of release *) admit. }
      
      { (* the case of makelock *) admit. }
      
      { (* the case of freelock *) admit. }
      
      { (* the case of spawn *) admit. }
    }
    (* end of Kblocked *)
    
    (* thread[i] is in Kresume *)
    {
      (* goes to Krun ci' with after_ex ci = ci'  *)
      destruct ci as [ve te k | ef sig args lid ve te k] eqn:Heqc.
      
      - (* contradiction: has to be an extcall *)
        specialize (wellformed i cnti).
        rewrite Eci in wellformed.
        simpl in wellformed.
        tauto.
      
      - (* extcall *)
        pose (ci':=
                match lid with
                | Some id => State ve (Maps.PTree.set id (Vint Int.zero) te) k
                | None => State ve te k
                end).
        exists (m, ge, (i :: sch, ThreadPool.updThreadC cnti (Krun ci')))(* ; split *).
        + (* taking the step Kresum->Krun *)
          constructor.
          apply JuicyMachine.resume_step with (tid := i) (Htid := cnti).
          * reflexivity.
          * eapply mem_compatible_forget. eauto.
          * eapply JuicyMachine.ResumeThread with (c := ci) (c' := ci').
            -- subst. reflexivity.
            -- subst. simpl. destruct lid; reflexivity.
            -- rewrite Eci.
               subst ci.
               f_equal.
               specialize (wellformed i cnti).
               rewrite Eci in wellformed.
               simpl in wellformed.
               tauto.
            -- constructor.
            -- reflexivity.
(* PRESERVATION
        + (* invariant again. (roughly same as in Krun -> Kblocked,
             but simpler.) *)
          (* leaving this as a TODO as there is a good chance that the
             invariant will change when proving Kblocked->Kresume *)
          admit.
*)
    }
    (* end of Kresume *)
    
    (* thread[i] is in Kinit *)
    {
      eexists(* ; split *).
      - constructor.
        apply JuicyMachine.start_step with (tid := i) (Htid := cnti).
        + reflexivity.
        + eapply mem_compatible_forget. eauto.
        + eapply JuicyMachine.StartThread.
          * apply Eci.
          * simpl.
            (* WE SAID THAT THIS SHOULD NOT BE IN THE MACHINE? *) 
            (* Maybe this is impossible and I have to do all the spawn
               work by myself. *)
           admit.
          * constructor.
          * reflexivity.
(*      - (* invariant: this complicates things quite a lot. I'll have
           to put horrible things in my invariant?  We'll see
           later. *)
        admit.
*)
    }
    (* end of Kinit *)
*)
  Admitted.

  Lemma state_invariant_step Gamma n state :
    state_invariant Jspec' Gamma (S n) state ->
    exists state',
      state_step state state' /\
      state_invariant Jspec' Gamma n state'.
  Proof.
    intros inv.
    destruct (progress _ _ _ inv) as (state', step).
    exists state'; split; [ now apply step | ].
    eapply preservation; eauto.
  Qed.
  
End Simulation.

Inductive jmsafe : nat -> cm_state -> Prop :=
| jmsafe_0 m ge sch tp : jmsafe 0 (m, ge, (sch, tp))
| jmsafe_halted n m ge tp : jmsafe n (m, ge, (nil, tp))
| jmsafe_core n m m' ge sch tp tp':
    @JuicyMachine.machine_step ge sch nil tp m sch nil tp' m' ->
    jmsafe n (m', ge, (sch, tp')) ->
    jmsafe (S n) (m, ge, (sch, tp))
| jmsafe_sch n m m' ge i sch tp tp':
    @JuicyMachine.machine_step ge (i :: sch) nil tp m sch nil tp' m' ->
    (forall sch', jmsafe n (m', ge, (sch', tp'))) ->
    jmsafe (S n) (m, ge, (i :: sch, tp)).

Lemma step_sch_irr ge i sch sch' tp m tp' m' :
  @JuicyMachine.machine_step ge (i :: sch) nil tp m sch nil tp' m' ->
  @JuicyMachine.machine_step ge (i :: sch') nil tp m sch' nil tp' m'.
Proof.
  intros step.
  assert (i :: sch <> sch) by (clear; induction sch; congruence).
  inversion step; try solve [exfalso; eauto].
  - now eapply JuicyMachine.suspend_step; eauto.
  - now eapply JuicyMachine.sync_step; eauto.
  - now eapply JuicyMachine.halted_step; eauto.
  - now eapply JuicyMachine.schedfail; eauto.
Qed.

(*+ Final instantiation *)

Section Safety.
  Variables
    (CS : compspecs)
    (V : varspecs)
    (G : funspecs)
    (ext_link : string -> ident)
    (ext_link_inj : forall s1 s2, ext_link s1 = ext_link s2 -> s1 = s2)
    (prog : program)
    (all_safe : semax_prog.semax_prog (Concurrent_Oracular_Espec CS ext_link) prog V G)
    (init_mem_not_none : Genv.init_mem prog <> None).

  Lemma invariant_safe Gamma n state :
    state_invariant (Jspec' CS ext_link) Gamma n state -> jmsafe n state.
  Proof.
    intros INV.
    pose proof (progress CS ext_link ext_link_inj) as Progress.
    pose proof (preservation CS ext_link ext_link_inj) as Preservation.
    revert state INV.
    induction n; intros ((m, ge), (sch, tp)) INV.
    - apply jmsafe_0.
    - destruct sch.
      + apply jmsafe_halted.
      + destruct (Progress _ _ _ INV) as (state', step).
        pose proof (Preservation _ _ _ _ step INV).
        inversion step as [ | ge' m0 m' sch' sch'' tp0 tp' jmstep ]; subst; simpl in *.
        inversion jmstep; subst.
        * eapply jmsafe_core; eauto.
        * eapply jmsafe_core; eauto.
        * eapply jmsafe_core; eauto.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m', ge, (t0 :: sch', tp)) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply state_invariant_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m, ge, (t0 :: sch', tp)) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply state_invariant_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m', ge, (t0 :: sch', tp')) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply state_invariant_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
        * eapply jmsafe_sch; eauto.
          intros sch'; apply IHn.
          eapply (step_sch_irr _ _ _ sch') in jmstep.
          simpl in *.
          assert (step' : state_step (m', ge, (t0 :: sch', tp')) (m', ge, (sch', tp'))).
          { constructor; auto. }
          eapply state_invariant_sch_irr in INV.
          specialize (Preservation _ _ _ _ step' INV).
          assumption.
  Qed.
  
  Definition init_mem : { m | Genv.init_mem prog = Some m } := init_m prog init_mem_not_none.
  
  Definition spr :=
    semax_prog_rule
      (Concurrent_Oracular_Espec CS ext_link) V G prog
      (proj1_sig init_mem) all_safe (proj2_sig init_mem).
  
  Definition initial_corestate : corestate := projT1 (projT2 spr).
  
  Definition initial_jm (n : nat) : juicy_mem := proj1_sig (snd (projT2 (projT2 spr)) n).
  
  Definition initial_machine_state (n : nat) :=
    ThreadPool.mk
      (pos.mkPos (le_n 1))
      (fun _ => Krun initial_corestate)
      (fun _ => m_phi (initial_jm n))
      (addressFiniteMap.AMap.empty _).

  Definition NoExternal_Espec : external_specification mem external_function unit :=
    Build_external_specification
      _ _ _
      (* no external calls from the machine *)
      (fun _ => False)
      (fun _ _ _ _ _ _ _ => False)
      (fun _ _ _ _ _ _ _ => False)
      (* when the machine is halted, it means no more schedule, there
      is nothing to check: *)
      (fun _ _ _ => Logic.True).
  
  Definition NoExternal_Hrel : nat -> mem -> mem -> Prop := fun _ _ _ => False.
  
  (* We state the theorem in terms of [safeN_] but because there are
  no external, this really just says that the initial state is
  "angelically safe" : for every schedule and every fuel n, there is a
  path either ending on an empty schedule or consuming all the
  fuel. *)
  
  Theorem safe_initial_state : forall sch r n genv_symb,
      safeN_
        (G := genv)
        (C := schedule * list _ * ThreadPool.t)
        (M := mem)
        (Z := unit)
        (genv_symb := genv_symb)
        (Hrel := NoExternal_Hrel)
        (JuicyMachine.MachineSemantics sch r)
        NoExternal_Espec
        (globalenv prog)
        n
        tt
        (sch, nil, initial_machine_state n)
        (proj1_sig init_mem).
  Proof.
    intros sch r n thisfunction.
    pose proof initial_invariant CS V G ext_link prog as INIT.
    repeat (specialize (INIT ltac:(assumption))).
    pose proof state_invariant_step CS ext_link ext_link_inj as SIM.
    revert INIT.
    unfold initial_state, initial_machine_state.
    unfold initial_corestate, initial_jm, spr, init_mem.
    match goal with |- context[(sch, ?tp)] => generalize tp end.
    match goal with |- context[(proj1_sig ?m)] => generalize (proj1_sig m) end.
    (* here we decorelate the CoreSemantics parameters from the
    initial state parameters *)
    generalize sch at 2.
    generalize (globalenv prog), sch.
    clear -SIM.
    induction n; intros g sch schSEM m t INV; [ now constructor | ].
    destruct (SIM _ _ _ INV) as [cm' [step INV']].
    inversion step as [ | ? ? m' ? sch' ? tp' STEP ]; subst; clear step.
    - (* empty schedule *)
      eapply safeN_halted.
      + reflexivity.
      + apply I.
    - (* a step can be taken *)
      eapply safeN_step with (c' := (sch', nil, tp')) (m'0 := m').
      + eapply STEP.
      + apply IHn.
        apply INV'.
  Qed.
  
  (* The following is a slightly stronger result, proving [jmsafe]
  i.e. a safety that universally quantifies over all schedule each
  time a part of the schedule is consumed *)

  Theorem jmsafe_initial_state sch n :
    jmsafe n ((proj1_sig init_mem, globalenv prog), (sch, initial_machine_state n)).
  Proof.
    eapply invariant_safe, initial_invariant.
  Qed.
  
  Lemma jmsafe_csafe n m ge sch s : jmsafe n (m, ge, (sch, s)) -> JuicyMachine.csafe ge (sch, nil, s) m n.
  Proof.
    clear.
    revert m ge sch s; induction n; intros m ge sch s SAFE.
    now constructor 1.
    inversion SAFE; subst.
    - constructor 2. reflexivity.
    - econstructor 3; simpl; eauto.
    - econstructor 4; simpl; eauto.
  Qed.
  
  (* [jmsafe] is used as a intermediary, eventually we'll prove
  [csafe] directly *)
  
  Theorem safety_initial_state (sch : schedule) (n : nat) :
    JuicyMachine.csafe (globalenv prog) (sch, nil, initial_machine_state n) (proj1_sig init_mem) n.
  Proof.
    apply jmsafe_csafe, jmsafe_initial_state.
  Qed.
  
End Safety.
