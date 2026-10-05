// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One GenHandle table: vkCreateDevice ALLOCs DEVICE from the physical
// device id, vkGetDeviceQueue LOOKUPs that DEVICE then ALLOCs QUEUE,
// vkAllocateMemory LOOKUPs DEVICE then ALLOCs MEMORY, vkCreateBuffer
// LOOKUPs DEVICE then ALLOCs BUFFER, vkAllocateCommandBuffers ALLOCs
// CMDBUF, vkBeginCommandBuffer looks
// up that published handle, vkCreateShaderModule commits SPIR-V under
// MODULE, vkCmdDispatch looks up that begun CMDBUF and kicks
// SpirvSubset, vkEndCommandBuffer looks up the begun handle and ends
// recording, vkQueueSubmit looks up the ended handle against that
// QUEUE, and vkQueueWaitIdle requires the prior submit. GetQueue
// before CreateDevice, begin before allocate, dispatch before begin
// or create, end before begin, submit before queue or end,
// MODULE-as-cmdbuf, and vkCreateInstance fault. Enable=0 elaborates
// no datapath. Not wired into g6lc_apu_sys. FeatureVirgl stays
// illegal.

// BeginRun (bru): QUEUE ALLOC, CMDBUF ALLOC, BEGIN LOOKUP, CREATE, DISPATCH, END LOOKUP, SUBMIT, WAIT on one table. Default-off. FeatureVirgl stays illegal.
// Interplay: BeginRun (bru) --> VenusCreateInstance (vci) --> VenusEnumeratePhys (vep) --> VenusPhysFeatures (vpf) --> VenusPhysProps (vpp) --> VenusQueueFamily (vqf) --> VenusCreateDevice (vcd) --> VenusGetQueue (vgq) --> VenusAllocMemory (vam) --> VenusCreateBuffer (vxb) --> VenusEncode (vnenc) --> GenHandle (gnh) --> VenusBegin (vbg) --> VenusEnd (ven) --> VenusSubmit (vqs) --> VenusWaitIdle (vwi) --> VenusDispatch (vnd) --> SpirvSubset (spirv) --? EndAlloc (eal) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_bru
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_bru_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_bru_cpl_t cpl_o,
  output apu_bru_t bru_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign bru_o = '0;
    assign irq_o = 1'b0;
    assign result_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i) | (|req_i) | (|in_a_i) |
                    (|in_b_i);
  end else begin : gen_on
    typedef enum logic [7:0] {
      Idle, FireVbg, WaitVbg, FireVen, WaitVen, FireVqs, WaitVqs, FireVwi,
      WaitVwi, FireVgq, WaitVgq, FireVcd, WaitVcd, FireVci, WaitVci, FireVep,
      WaitVep, FireVqf, WaitVqf, FireVpf, WaitVpf, FireVpp, WaitVpp, FireVmp,
      WaitVmp, FireVam, WaitVam, FireVxb, WaitVxb, FireVbb, WaitVbb, FireVmm,
      WaitVmm, FireVum, WaitVum, FireVbm, WaitVbm, FireVfm, WaitVfm, FireVim, WaitVim, FireVmc, WaitVmc, FireVdl, WaitVdl, FireVpl, WaitVpl, FireVcp, WaitVcp, FireVda, WaitVda, FireVud, WaitVud, FireVbp, WaitVbp, FireVbd, WaitVbd, FireVpo, WaitVpo, FireVxi, WaitVxi, FireVbi, WaitVbi, FireVmi, WaitVmi, FireVxv, WaitVxv, FireVsm, WaitVsm, FireVrp, WaitVrp, FireVgp, WaitVgp, FireVfb, WaitVfb, FireVrb, WaitVrb, FireVdw, WaitVdw, FireVre, WaitVre, FireVvb, WaitVvb, FireVib, WaitVib, FireVdi, WaitVdi, FireVvp, WaitVvp, FireVsi, WaitVsi, FireVpb, WaitVpb, FireVns, WaitVns, FireVdf, WaitVdf, FireVdx, WaitVdx, FireVdk, WaitVdk, FireVdr, WaitVdr, FireVdb, WaitVdb, FireVdg, WaitVdg, FireVfe, WaitVfe, FireVdm, WaitVdm, FireVdp, WaitVdp, FireVdy, WaitVdy, FireVdt, WaitVdt, FireVdq, WaitVdq, FireVfs, WaitVfs, FireVrc, WaitVrc, FireVfc, WaitVfc, FireVdd, WaitVdd, FireVpc, WaitVpc, FireVdc, WaitVdc, FireVdn, WaitVdn, FireVgf, WaitVgf, FireVip, WaitVip, FireVxe, WaitVxe, FireVrd, WaitVrd, FireVie, WaitVie, FireVwl, WaitVwl, FireVsl, WaitVsl, FireVrg, WaitVrg, FireVlw, WaitVlw, FireVzb, WaitVzb, FireVbc, WaitVbc, FireVbo, WaitVbo, FireVcm, WaitVcm, FireVwm, WaitVwm, FireVrf, WaitVrf, FireVcc, WaitVcc, FireVcy, WaitVcy, FireVbl, WaitVbl, FireVbt, WaitVbt, FireVic, WaitVic, FireVub, WaitVub, FireVfl, WaitVfl, FireVcl, WaitVcl, FireVio, WaitVio, FireVix, WaitVix, FireVds, WaitVds, FireVat, WaitVat, FireVin, WaitVin, FireVrs, WaitVrs, FireVgs, WaitVgs, FireVwf, WaitVwf, FireVfr, WaitVfr, FireVfn, WaitVfn, FireEnc,
      WaitEnc, FireVnd,
      WaitVnd, FireGnh, WaitGnh, Load, Commit, Kick, WaitEx, Done
    } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VAC_WORDS];
    apu_bru_cpl_t cpl_q;
    apu_bru_t rec_q;
    logic alloc_q, begin_q, end_q, create_q, disp_q, submit_q, wait_q, queue_q;
    logic device_q, instance_q, enum_q, look_q, loaded_q, begun_q, ended_q;
    logic submitted_q, queued_q, instanced_q, qfam_q, qfam_ok_q;
    logic feat_q, props_q, mem_q, vkmem_q, buffer_q, bind_q, bind_mem_q;
    logic feat_ok_q, props_ok_q, mem_ok_q, bind_ok_q, map_q, map_ok_q, unmap_q;
    logic bufreq_q, flush_q, inval_q, memc_q, dsl_q, pl_q, cpipe_q;
    logic dsl_ok_q, pl_ok_q, dset_q, upd_q, upd_buf_q, bp_q, bd_q;
    logic dset_ok_q, pipe_bound_q, desc_bound_q;
    logic pool_q, img_q, bindimg_q, bindimg_mem_q, imgreq_q, dset_pool_q;
    logic pool_ok_q;
    logic [31:0] pool_h_q;
    logic view_q, samp_q, rpass_q, gpipe_q, rp_ok_q;
    logic fbuf_q, beginrp_q, draw_q, endrp_q, fbuf_ok_q, in_rp_q;
    logic vtx_q, idxb_q, drawi_q, vtx_buf_q, idx_buf_q, vtx_bound_q, idx_bound_q;
    logic vp_q, sc_q, bar_q, nextsp_q;
    logic dfb_q, dvw_q, dsm_q, drp_q, dfb_ret_q, dvw_ret_q, dsm_ret_q, drp_ret_q;
    logic dbf_q, dim_q, fme_q, dmd_q, dbf_ret_q, dim_ret_q, fme_ret_q, dmd_ret_q;
    logic dpl_q, dyo_q, dds_q, dpo_q, dpl_ret_q, dyo_ret_q, dds_ret_q, dpo_ret_q;
    logic fds_q, rcb_q, fcb_q, ddv_q, fds_ret_q, fcb_ret_q, ddv_ret_q;
    logic rcp_q, dcp_q, din_q, din_ret_q;
    logic fmt_q, ifmt_q, dext_q, rdp_q;
    logic iex_q, dwi_q, isl_q, rag_q;
    logic slw_q, sdb_q, sbc_q, sbb_q;
    logic scm_q, swm_q, srf_q;
    logic ccb_q, cci_q, bli_q, cbi_q, copy_src_q, copy_dst_q;
    logic cib_q, ubu_q, fil_q, ccl_q;
    logic dinr_q, didi_q, cds_q, cat_q;
    logic dsi_q, rsl_q;
    logic gfs_q, wfe_q, rfe_q, dfe_q;
    logic [7:0] load_q, n_q, enc_idx;
    logic [31:0] in_a_q, in_b_q, result_q, enc_rdata, vnd_rdata, vbg_rdata;
    logic [31:0] ven_rdata, vqs_rdata, vwi_rdata, vgq_rdata, vcd_rdata, vci_rdata;
    logic [31:0] vep_rdata, vqf_rdata, vpf_rdata, vpp_rdata, vmp_rdata, vam_rdata;
    logic [31:0] vxb_rdata, vbb_rdata, vmm_rdata, vum_rdata, vbm_rdata, vfm_rdata;
    logic [31:0] vim_rdata, vmc_rdata, vdl_rdata, vpl_rdata, vcp_rdata;
    logic [31:0] vda_rdata, vud_rdata, vbp_rdata, vbd_rdata;
    logic [31:0] vpo_rdata, vxi_rdata, vbi_rdata, vmi_rdata;
    logic [31:0] vxv_rdata, vsm_rdata, vrp_rdata, vgp_rdata;
    logic [31:0] vfb_rdata, vrb_rdata, vdw_rdata, vre_rdata;
    logic [31:0] vvb_rdata, vib_rdata, vdi_rdata;
    logic [31:0] vvp_rdata, vsi_rdata, vpb_rdata, vns_rdata;
    logic [31:0] vdf_rdata, vdx_rdata, vdk_rdata, vdr_rdata;
    logic [31:0] vdb_rdata, vdg_rdata, vfe_rdata, vdm_rdata;
    logic [31:0] vdp_rdata, vdy_rdata, vdt_rdata, vdq_rdata;
    logic [31:0] vfs_rdata, vrc_rdata, vfc_rdata, vdd_rdata;
    logic [31:0] vpc_rdata, vdc_rdata, vdn_rdata;
    logic [31:0] vgf_rdata, vip_rdata, vxe_rdata, vrd_rdata;
    logic [31:0] vie_rdata, vwl_rdata, vsl_rdata, vrg_rdata;
    logic [31:0] vlw_rdata, vzb_rdata, vbc_rdata, vbo_rdata;
    logic [31:0] vcm_rdata, vwm_rdata, vrf_rdata;
    logic [31:0] vcc_rdata, vcy_rdata, vbl_rdata, vbt_rdata;
    logic [31:0] vic_rdata, vub_rdata, vfl_rdata, vcl_rdata;
    logic [31:0] vio_rdata, vix_rdata, vds_rdata, vat_rdata;
    logic [31:0] vin_rdata, vrs_rdata;
    logic [31:0] vgs_rdata, vwf_rdata, vfr_rdata, vfn_rdata;
    logic [31:0] begun_handle_q, ended_handle_q, queue_handle_q, begin_flags_q;
    logic [31:0] qreply0_q, qreply1_q;
    logic [31:0] dreply_q [0:5];
    logic [31:0] ireply_q [0:5];
    logic [31:0] preply_q [0:5];
    logic [31:0] freply_q [0:5];
    logic [31:0] ereply_q [0:5];
    logic [31:0] sreply_q [0:5];
    logic [31:0] mreply_q [0:5];
    logic [31:0] areply_q [0:5];
    logic [31:0] breply_q [0:5];
    logic [31:0] nreply_q [0:5];
    logic [31:0] ureply_q [0:5];
    logic [31:0] wreply_q [0:5];
    logic [31:0] xreply_q [0:5];
    logic [31:0] yreply_q [0:5];
    logic [31:0] zreply_q [0:5];
    logic [31:0] creply_q [0:5];
    logic [31:0] lreply_q [0:5];
    logic [31:0] kreply_q [0:5];
    logic [31:0] oreply_q [0:5];
    logic [31:0] jreply_q [0:5];
    logic [31:0] treply_q [0:5];
    logic [31:0] hreply_q [0:5];
    logic [31:0] greply_q [0:5];
    logic [31:0] rreply_q [0:5];
    logic [31:0] ximg_q [0:5];
    logic [31:0] bimg_q [0:5];
    logic [31:0] mimg_q [0:5];
    logic [31:0] tail_q [0:7];
    logic [31:0] cmd, flags, stype, level, count;
    logic [63:0] pinfo, pnext, pool, asz, guest;
    logic decode_ok, want_reply;
    logic enc_req, enc_rdy, enc_cpl, enc_ack, enc_we;
    logic vnd_req, vnd_rdy, vnd_cpl, vnd_ack, vnd_we;
    logic vbg_req, vbg_rdy, vbg_cpl, vbg_ack, vbg_we;
    logic ven_req, ven_rdy, ven_cpl, ven_ack, ven_we;
    logic vqs_req, vqs_rdy, vqs_cpl, vqs_ack, vqs_we;
    logic vwi_req, vwi_rdy, vwi_cpl, vwi_ack, vwi_we;
    logic vgq_req, vgq_rdy, vgq_cpl, vgq_ack, vgq_we;
    logic vcd_req, vcd_rdy, vcd_cpl, vcd_ack, vcd_we;
    logic vci_req, vci_rdy, vci_cpl, vci_ack, vci_we;
    logic vep_req, vep_rdy, vep_cpl, vep_ack, vep_we;
    logic vqf_req, vqf_rdy, vqf_cpl, vqf_ack, vqf_we;
    logic vpf_req, vpf_rdy, vpf_cpl, vpf_ack, vpf_we;
    logic vpp_req, vpp_rdy, vpp_cpl, vpp_ack, vpp_we;
    logic vmp_req, vmp_rdy, vmp_cpl, vmp_ack, vmp_we;
    logic vam_req, vam_rdy, vam_cpl, vam_ack, vam_we;
    logic vxb_req, vxb_rdy, vxb_cpl, vxb_ack, vxb_we;
    logic vbb_req, vbb_rdy, vbb_cpl, vbb_ack, vbb_we;
    logic vmm_req, vmm_rdy, vmm_cpl, vmm_ack, vmm_we;
    logic vum_req, vum_rdy, vum_cpl, vum_ack, vum_we;
    logic vbm_req, vbm_rdy, vbm_cpl, vbm_ack, vbm_we;
    logic vfm_req, vfm_rdy, vfm_cpl, vfm_ack, vfm_we;
    logic vim_req, vim_rdy, vim_cpl, vim_ack, vim_we;
    logic vmc_req, vmc_rdy, vmc_cpl, vmc_ack, vmc_we;
    logic vdl_req, vdl_rdy, vdl_cpl, vdl_ack, vdl_we;
    logic vpl_req, vpl_rdy, vpl_cpl, vpl_ack, vpl_we;
    logic vcp_req, vcp_rdy, vcp_cpl, vcp_ack, vcp_we;
    logic vda_req, vda_rdy, vda_cpl, vda_ack, vda_we;
    logic vud_req, vud_rdy, vud_cpl, vud_ack, vud_we;
    logic vbp_req, vbp_rdy, vbp_cpl, vbp_ack, vbp_we;
    logic vbd_req, vbd_rdy, vbd_cpl, vbd_ack, vbd_we;
    logic vpo_req, vpo_rdy, vpo_cpl, vpo_ack, vpo_we;
    logic vxi_req, vxi_rdy, vxi_cpl, vxi_ack, vxi_we;
    logic vbi_req, vbi_rdy, vbi_cpl, vbi_ack, vbi_we;
    logic vmi_req, vmi_rdy, vmi_cpl, vmi_ack, vmi_we;
    logic vxv_req, vxv_rdy, vxv_cpl, vxv_ack, vxv_we;
    logic vsm_req, vsm_rdy, vsm_cpl, vsm_ack, vsm_we;
    logic vrp_req, vrp_rdy, vrp_cpl, vrp_ack, vrp_we;
    logic vgp_req, vgp_rdy, vgp_cpl, vgp_ack, vgp_we;
    logic vfb_req, vfb_rdy, vfb_cpl, vfb_ack, vfb_we;
    logic vrb_req, vrb_rdy, vrb_cpl, vrb_ack, vrb_we;
    logic vdw_req, vdw_rdy, vdw_cpl, vdw_ack, vdw_we;
    logic vre_req, vre_rdy, vre_cpl, vre_ack, vre_we;
    logic vvb_req, vvb_rdy, vvb_cpl, vvb_ack, vvb_we;
    logic vib_req, vib_rdy, vib_cpl, vib_ack, vib_we;
    logic vdi_req, vdi_rdy, vdi_cpl, vdi_ack, vdi_we;
    logic vvp_req, vvp_rdy, vvp_cpl, vvp_ack, vvp_we;
    logic vsi_req, vsi_rdy, vsi_cpl, vsi_ack, vsi_we;
    logic vpb_req, vpb_rdy, vpb_cpl, vpb_ack, vpb_we;
    logic vns_req, vns_rdy, vns_cpl, vns_ack, vns_we;
    logic vdf_req, vdf_rdy, vdf_cpl, vdf_ack, vdf_we;
    logic vdx_req, vdx_rdy, vdx_cpl, vdx_ack, vdx_we;
    logic vdk_req, vdk_rdy, vdk_cpl, vdk_ack, vdk_we;
    logic vdr_req, vdr_rdy, vdr_cpl, vdr_ack, vdr_we;
    logic vdb_req, vdb_rdy, vdb_cpl, vdb_ack, vdb_we;
    logic vdg_req, vdg_rdy, vdg_cpl, vdg_ack, vdg_we;
    logic vfe_req, vfe_rdy, vfe_cpl, vfe_ack, vfe_we;
    logic vdm_req, vdm_rdy, vdm_cpl, vdm_ack, vdm_we;
    logic vdp_req, vdp_rdy, vdp_cpl, vdp_ack, vdp_we;
    logic vdy_req, vdy_rdy, vdy_cpl, vdy_ack, vdy_we;
    logic vdt_req, vdt_rdy, vdt_cpl, vdt_ack, vdt_we;
    logic vdq_req, vdq_rdy, vdq_cpl, vdq_ack, vdq_we;
    logic vfs_req, vfs_rdy, vfs_cpl, vfs_ack, vfs_we;
    logic vrc_req, vrc_rdy, vrc_cpl, vrc_ack, vrc_we;
    logic vfc_req, vfc_rdy, vfc_cpl, vfc_ack, vfc_we;
    logic vdd_req, vdd_rdy, vdd_cpl, vdd_ack, vdd_we;
    logic vpc_req, vpc_rdy, vpc_cpl, vpc_ack, vpc_we;
    logic vdc_req, vdc_rdy, vdc_cpl, vdc_ack, vdc_we;
    logic vdn_req, vdn_rdy, vdn_cpl, vdn_ack, vdn_we;
    logic vgf_req, vgf_rdy, vgf_cpl, vgf_ack, vgf_we;
    logic vip_req, vip_rdy, vip_cpl, vip_ack, vip_we;
    logic vxe_req, vxe_rdy, vxe_cpl, vxe_ack, vxe_we;
    logic vrd_req, vrd_rdy, vrd_cpl, vrd_ack, vrd_we;
    logic vie_req, vie_rdy, vie_cpl, vie_ack, vie_we;
    logic vwl_req, vwl_rdy, vwl_cpl, vwl_ack, vwl_we;
    logic vsl_req, vsl_rdy, vsl_cpl, vsl_ack, vsl_we;
    logic vrg_req, vrg_rdy, vrg_cpl, vrg_ack, vrg_we;
    logic vlw_req, vlw_rdy, vlw_cpl, vlw_ack, vlw_we;
    logic vzb_req, vzb_rdy, vzb_cpl, vzb_ack, vzb_we;
    logic vbc_req, vbc_rdy, vbc_cpl, vbc_ack, vbc_we;
    logic vbo_req, vbo_rdy, vbo_cpl, vbo_ack, vbo_we;
    logic vcm_req, vcm_rdy, vcm_cpl, vcm_ack, vcm_we;
    logic vwm_req, vwm_rdy, vwm_cpl, vwm_ack, vwm_we;
    logic vrf_req, vrf_rdy, vrf_cpl, vrf_ack, vrf_we;
    logic vcc_req, vcc_rdy, vcc_cpl, vcc_ack, vcc_we;
    logic vcy_req, vcy_rdy, vcy_cpl, vcy_ack, vcy_we;
    logic vbl_req, vbl_rdy, vbl_cpl, vbl_ack, vbl_we;
    logic vbt_req, vbt_rdy, vbt_cpl, vbt_ack, vbt_we;
    logic vic_req, vic_rdy, vic_cpl, vic_ack, vic_we;
    logic vub_req, vub_rdy, vub_cpl, vub_ack, vub_we;
    logic vfl_req, vfl_rdy, vfl_cpl, vfl_ack, vfl_we;
    logic vcl_req, vcl_rdy, vcl_cpl, vcl_ack, vcl_we;
    logic vio_req, vio_rdy, vio_cpl, vio_ack, vio_we;
    logic vix_req, vix_rdy, vix_cpl, vix_ack, vix_we;
    logic vds_req, vds_rdy, vds_cpl, vds_ack, vds_we;
    logic vat_req, vat_rdy, vat_cpl, vat_ack, vat_we;
    logic vin_req, vin_rdy, vin_cpl, vin_ack, vin_we;
    logic vrs_req, vrs_rdy, vrs_cpl, vrs_ack, vrs_we;
    logic vgs_req, vgs_rdy, vgs_cpl, vgs_ack, vgs_we;
    logic vwf_req, vwf_rdy, vwf_cpl, vwf_ack, vwf_we;
    logic vfr_req, vfr_rdy, vfr_cpl, vfr_ack, vfr_we;
    logic vfn_req, vfn_rdy, vfn_cpl, vfn_ack, vfn_we;
    logic gnh_req_v, gnh_rdy, gnh_cpl, gnh_ack;
    logic [3:0] vnd_idx, vbg_idx, ven_idx;
    logic [4:0] vqs_idx;
    logic [3:0] vwi_idx, vgq_idx;
    logic [5:0] vcd_idx;
    logic [4:0] vci_idx;
    logic [3:0] vep_idx, vqf_idx, vpf_idx, vpp_idx, vmp_idx;
    logic [4:0] vam_idx;
    logic [4:0] vxb_idx;
    logic [3:0] vbb_idx;
    logic [3:0] vmm_idx;
    logic [3:0] vum_idx;
    logic [3:0] vbm_idx;
    logic [4:0] vfm_idx;
    logic [4:0] vim_idx;
    logic [3:0] vmc_idx;
    logic [4:0] vdl_idx, vpl_idx, vcp_idx, vda_idx, vud_idx, vbd_idx, vpo_idx, vxi_idx, vxv_idx, vsm_idx, vrp_idx, vgp_idx, vfb_idx, vrb_idx, vcy_idx, vbl_idx, vbt_idx, vic_idx, vcl_idx, vds_idx, vat_idx, vrs_idx;
    logic [3:0] vdw_idx, vre_idx, vvb_idx, vib_idx, vdi_idx, vvp_idx, vsi_idx, vpb_idx, vns_idx, vdf_idx, vdx_idx, vdk_idx, vdr_idx, vdb_idx, vdg_idx, vfe_idx, vdm_idx, vdp_idx, vdy_idx, vdt_idx, vdq_idx, vfs_idx, vrc_idx, vfc_idx, vdd_idx, vpc_idx, vdc_idx, vdn_idx, vgf_idx, vip_idx, vxe_idx, vrd_idx, vie_idx, vwl_idx, vsl_idx, vrg_idx, vlw_idx, vzb_idx, vbc_idx, vbo_idx, vcm_idx, vwm_idx, vrf_idx, vcc_idx, vub_idx, vfl_idx, vio_idx, vix_idx, vin_idx, vgs_idx, vwf_idx, vfr_idx, vfn_idx;
    logic [3:0] vbi_idx, vmi_idx;
    logic [3:0] vbp_idx;
    logic spv_we, spv_commit, spv_start, spv_idle, spv_busy, spv_done;
    logic spv_fault, spv_irq;
    logic [6:0] spv_idx;
    logic [31:0] spv_wdata, spv_res;
    logic [7:0] spv_len;
    apu_gnh_req_t gnh_req_q;
    apu_vnenc_cpl_t enc_c;
    apu_vnenc_t enc_rec;
    apu_vnd_cpl_t vnd_c;
    apu_vnd_t vnd_rec;
    apu_vbg_cpl_t vbg_c;
    apu_vbg_t vbg_rec;
    apu_ven_cpl_t ven_c;
    apu_ven_t ven_rec;
    apu_vqs_cpl_t vqs_c;
    apu_vqs_t vqs_rec;
    apu_vwi_cpl_t vwi_c;
    apu_vwi_t vwi_rec;
    apu_vgq_cpl_t vgq_c;
    apu_vgq_t vgq_rec;
    apu_vcd_cpl_t vcd_c;
    apu_vcd_t vcd_rec;
    apu_vci_cpl_t vci_c;
    apu_vci_t vci_rec;
    apu_vep_cpl_t vep_c;
    apu_vep_t vep_rec;
    apu_vqf_cpl_t vqf_c;
    apu_vqf_t vqf_rec;
    apu_vpf_cpl_t vpf_c;
    apu_vpf_t vpf_rec;
    apu_vpp_cpl_t vpp_c;
    apu_vpp_t vpp_rec;
    apu_vmp_cpl_t vmp_c;
    apu_vmp_t vmp_rec;
    apu_vam_cpl_t vam_c;
    apu_vam_t vam_rec;
    apu_vxb_cpl_t vxb_c;
    apu_vxb_t vxb_rec;
    apu_vbb_cpl_t vbb_c;
    apu_vbb_t vbb_rec;
    apu_vmm_cpl_t vmm_c;
    apu_vmm_t vmm_rec;
    apu_vum_cpl_t vum_c;
    apu_vum_t vum_rec;
    apu_vbm_cpl_t vbm_c;
    apu_vbm_t vbm_rec;
    apu_vfm_cpl_t vfm_c;
    apu_vfm_t vfm_rec;
    apu_vim_cpl_t vim_c;
    apu_vim_t vim_rec;
    apu_vmc_cpl_t vmc_c;
    apu_vmc_t vmc_rec;
    apu_vdl_cpl_t vdl_c;
    apu_vdl_t vdl_rec;
    apu_vpl_cpl_t vpl_c;
    apu_vpl_t vpl_rec;
    apu_vcp_cpl_t vcp_c;
    apu_vcp_t vcp_rec;
    apu_vda_cpl_t vda_c;
    apu_vda_t vda_rec;
    apu_vud_cpl_t vud_c;
    apu_vud_t vud_rec;
    apu_vbp_cpl_t vbp_c;
    apu_vbp_t vbp_rec;
    apu_vbd_cpl_t vbd_c;
    apu_vbd_t vbd_rec;
    apu_vpo_cpl_t vpo_c;
    apu_vpo_t vpo_rec;
    apu_vxi_cpl_t vxi_c;
    apu_vxi_t vxi_rec;
    apu_vbi_cpl_t vbi_c;
    apu_vbi_t vbi_rec;
    apu_vmi_cpl_t vmi_c;
    apu_vmi_t vmi_rec;
    apu_vxv_cpl_t vxv_c;
    apu_vxv_t vxv_rec;
    apu_vsm_cpl_t vsm_c;
    apu_vsm_t vsm_rec;
    apu_vrp_cpl_t vrp_c;
    apu_vrp_t vrp_rec;
    apu_vgp_cpl_t vgp_c;
    apu_vgp_t vgp_rec;
    apu_vfb_cpl_t vfb_c;
    apu_vfb_t vfb_rec;
    apu_vrb_cpl_t vrb_c;
    apu_vrb_t vrb_rec;
    apu_vdw_cpl_t vdw_c;
    apu_vdw_t vdw_rec;
    apu_vre_cpl_t vre_c;
    apu_vre_t vre_rec;
    apu_vvb_cpl_t vvb_c;
    apu_vvb_t vvb_rec;
    apu_vib_cpl_t vib_c;
    apu_vib_t vib_rec;
    apu_vdi_cpl_t vdi_c;
    apu_vdi_t vdi_rec;
    apu_vvp_cpl_t vvp_c;
    apu_vvp_t vvp_rec;
    apu_vsi_cpl_t vsi_c;
    apu_vsi_t vsi_rec;
    apu_vpb_cpl_t vpb_c;
    apu_vpb_t vpb_rec;
    apu_vns_cpl_t vns_c;
    apu_vns_t vns_rec;
    apu_vdf_cpl_t vdf_c;
    apu_vdf_t vdf_rec;
    apu_vdx_cpl_t vdx_c;
    apu_vdx_t vdx_rec;
    apu_vdk_cpl_t vdk_c;
    apu_vdk_t vdk_rec;
    apu_vdr_cpl_t vdr_c;
    apu_vdr_t vdr_rec;
    apu_vdb_cpl_t vdb_c;
    apu_vdb_t vdb_rec;
    apu_vdg_cpl_t vdg_c;
    apu_vdg_t vdg_rec;
    apu_vfe_cpl_t vfe_c;
    apu_vfe_t vfe_rec;
    apu_vdm_cpl_t vdm_c;
    apu_vdm_t vdm_rec;
    apu_vdp_cpl_t vdp_c;
    apu_vdp_t vdp_rec;
    apu_vdy_cpl_t vdy_c;
    apu_vdy_t vdy_rec;
    apu_vdt_cpl_t vdt_c;
    apu_vdt_t vdt_rec;
    apu_vdq_cpl_t vdq_c;
    apu_vdq_t vdq_rec;
    apu_vfs_cpl_t vfs_c;
    apu_vfs_t vfs_rec;
    apu_vrc_cpl_t vrc_c;
    apu_vrc_t vrc_rec;
    apu_vfc_cpl_t vfc_c;
    apu_vfc_t vfc_rec;
    apu_vdd_cpl_t vdd_c;
    apu_vdd_t vdd_rec;
    apu_vpc_cpl_t vpc_c;
    apu_vpc_t vpc_rec;
    apu_vdc_cpl_t vdc_c;
    apu_vdc_t vdc_rec;
    apu_vdn_cpl_t vdn_c;
    apu_vdn_t vdn_rec;
    apu_vgf_cpl_t vgf_c;
    apu_vgf_t vgf_rec;
    apu_vip_cpl_t vip_c;
    apu_vip_t vip_rec;
    apu_vxe_cpl_t vxe_c;
    apu_vxe_t vxe_rec;
    apu_vrd_cpl_t vrd_c;
    apu_vrd_t vrd_rec;
    apu_vie_cpl_t vie_c;
    apu_vie_t vie_rec;
    apu_vwl_cpl_t vwl_c;
    apu_vwl_t vwl_rec;
    apu_vsl_cpl_t vsl_c;
    apu_vsl_t vsl_rec;
    apu_vrg_cpl_t vrg_c;
    apu_vrg_t vrg_rec;
    apu_vlw_cpl_t vlw_c;
    apu_vlw_t vlw_rec;
    apu_vzb_cpl_t vzb_c;
    apu_vzb_t vzb_rec;
    apu_vbc_cpl_t vbc_c;
    apu_vbc_t vbc_rec;
    apu_vbo_cpl_t vbo_c;
    apu_vbo_t vbo_rec;
    apu_vcm_cpl_t vcm_c;
    apu_vcm_t vcm_rec;
    apu_vwm_cpl_t vwm_c;
    apu_vwm_t vwm_rec;
    apu_vrf_cpl_t vrf_c;
    apu_vrf_t vrf_rec;
    apu_vcc_cpl_t vcc_c;
    apu_vcc_t vcc_rec;
    apu_vcy_cpl_t vcy_c;
    apu_vcy_t vcy_rec;
    apu_vbl_cpl_t vbl_c;
    apu_vbl_t vbl_rec;
    apu_vbt_cpl_t vbt_c;
    apu_vbt_t vbt_rec;
    apu_vic_cpl_t vic_c;
    apu_vic_t vic_rec;
    apu_vub_cpl_t vub_c;
    apu_vub_t vub_rec;
    apu_vfl_cpl_t vfl_c;
    apu_vfl_t vfl_rec;
    apu_vcl_cpl_t vcl_c;
    apu_vcl_t vcl_rec;
    apu_vio_cpl_t vio_c;
    apu_vio_t vio_rec;
    apu_vix_cpl_t vix_c;
    apu_vix_t vix_rec;
    apu_vds_cpl_t vds_c;
    apu_vds_t vds_rec;
    apu_vat_cpl_t vat_c;
    apu_vat_t vat_rec;
    apu_vin_cpl_t vin_c;
    apu_vin_t vin_rec;
    apu_vrs_cpl_t vrs_c;
    apu_vrs_t vrs_rec;
    apu_vgs_cpl_t vgs_c;
    apu_vgs_t vgs_rec;
    apu_vwf_cpl_t vwf_c;
    apu_vwf_t vwf_rec;
    apu_vfr_cpl_t vfr_c;
    apu_vfr_t vfr_rec;
    apu_vfn_cpl_t vfn_c;
    apu_vfn_t vfn_rec;
    apu_gnh_cpl_t gnh_c;
    apu_gnh_t gnh_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_bru_cpl_t'('0);
    assign bru_o = rec_q;
    assign irq_o = state_q == Done && rec_q.valid && rec_q.dispatch;
    assign result_o = result_q;
    assign cs_rdata_o = (cs_idx_i[7:3] == 5'd31) ?
                        tail_q[cs_idx_i[2:0]] :
                        ((cs_idx_i[7:3] == 5'd30 && cs_idx_i[2:0] < 3'd6) ?
                        mimg_q[cs_idx_i[2:0]] :
                        ((cs_idx_i[7:3] == 5'd29 && cs_idx_i[2:0] < 3'd6) ?
                         bimg_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd28 && cs_idx_i[2:0] < 3'd6) ?
                          ximg_q[cs_idx_i[2:0]] :
                          ((cs_idx_i[7:3] == 5'd27 && cs_idx_i[2:0] < 3'd6) ?
                           rreply_q[cs_idx_i[2:0]] :
                           ((cs_idx_i[7:3] == 5'd26 && cs_idx_i[2:0] < 3'd6) ?
                        greply_q[cs_idx_i[2:0]] :
                        ((cs_idx_i[7:3] == 5'd25 && cs_idx_i[2:0] < 3'd6) ?
                         hreply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd24 && cs_idx_i[2:0] < 3'd6) ?
                          treply_q[cs_idx_i[2:0]] :
                          ((cs_idx_i[7:3] == 5'd23 && cs_idx_i[2:0] < 3'd6) ?
                           jreply_q[cs_idx_i[2:0]] :
                           ((cs_idx_i[7:3] == 5'd22 && cs_idx_i[2:0] < 3'd6) ?
                        oreply_q[cs_idx_i[2:0]] :
                        ((cs_idx_i[7:3] == 5'd21 && cs_idx_i[2:0] < 3'd6) ?
                         kreply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd20 && cs_idx_i[2:0] < 3'd6) ?
                          lreply_q[cs_idx_i[2:0]] :
                          ((cs_idx_i[7:3] == 5'd19 && cs_idx_i[2:0] < 3'd6) ?
                        creply_q[cs_idx_i[2:0]] :
                        ((cs_idx_i[7:3] == 5'd18 && cs_idx_i[2:0] < 3'd6) ?
                         zreply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd17 && cs_idx_i[2:0] < 3'd6) ?
                        yreply_q[cs_idx_i[2:0]] :
                        ((cs_idx_i[7:3] == 5'd16 && cs_idx_i[2:0] < 3'd6) ?
                         xreply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd15 && cs_idx_i[2:0] < 3'd6) ?
                          wreply_q[cs_idx_i[2:0]] :
                          ((cs_idx_i[7:3] == 5'd14 && cs_idx_i[2:0] < 3'd6) ?
                         ureply_q[cs_idx_i[2:0]] :
                        ((cs_idx_i[7:3] == 5'd13 && cs_idx_i[2:0] < 3'd6) ?
                         nreply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd12 && cs_idx_i[2:0] < 3'd6) ?
                         breply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd11 && cs_idx_i[2:0] < 3'd6) ?
                         areply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd10 && cs_idx_i[2:0] < 3'd6) ?
                         mreply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd9 && cs_idx_i[2:0] < 3'd6) ?
                         sreply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd8 && cs_idx_i[2:0] < 3'd6) ?
                         ereply_q[cs_idx_i[2:0]] :
                         ((cs_idx_i[7:3] == 5'd7 && cs_idx_i[2:0] < 3'd6) ?
                          freply_q[cs_idx_i[2:0]] :
                          ((cs_idx_i[7:3] == 5'd6 && cs_idx_i[2:0] < 3'd6) ?
                           preply_q[cs_idx_i[2:0]] :
                           ((cs_idx_i[7:3] == 5'd5 && cs_idx_i[2:0] < 3'd6) ?
                            ireply_q[cs_idx_i[2:0]] :
                            ((cs_idx_i[7:3] == 5'd4 && cs_idx_i[2:0] < 3'd6) ?
                             dreply_q[cs_idx_i[2:0]] :
                             ((cs_idx_i[7:3] == 5'd0 && cs_idx_i[2:1] == 2'b11) ?
                              (cs_idx_i[0] ? qreply1_q : qreply0_q) :
                              ((cs_idx_i >= 8'd24 && cs_idx_i < 8'd32) ? vqs_rdata :
                               ((cs_idx_i[7:4] == 4'd0 && !cs_idx_i[3]) ? ven_rdata :
                                ((cs_idx_i[7:4] == 4'd0) ? vbg_rdata :
                                 ((cs_idx_i < 8'(APU_VAC_WORDS)) ? cs_q[cs_idx_i[4:0]]
                                                                : enc_rdata))))))))))))))))))))))))))))))));
    assign enc_we = cs_we_i && (state_q == Idle);
    assign enc_idx = (state_q == Load) ? (8'(APU_VNENC_CODE0) + load_q) : cs_idx_i;
    assign vnd_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vnd_idx = cs_idx_i[3:0];
    assign vbg_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vbg_idx = cs_idx_i[3:0];
    assign ven_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign ven_idx = cs_idx_i[3:0];
    assign vqs_we = enc_we && (cs_idx_i < 8'd32);
    assign vqs_idx = cs_idx_i[4:0];
    assign vwi_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vwi_idx = cs_idx_i[3:0];
    assign vgq_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vgq_idx = cs_idx_i[3:0];
    assign vcd_we = enc_we && (cs_idx_i < 8'(APU_VCD_WORDS));
    assign vcd_idx = cs_idx_i[5:0];
    assign vci_we = enc_we && (cs_idx_i < 8'(APU_VCI_WORDS));
    assign vci_idx = cs_idx_i[4:0];
    assign vep_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vep_idx = cs_idx_i[3:0];
    assign vqf_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vqf_idx = cs_idx_i[3:0];
    assign vpf_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vpf_idx = cs_idx_i[3:0];
    assign vpp_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vpp_idx = cs_idx_i[3:0];
    assign vmp_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vmp_idx = cs_idx_i[3:0];
    assign vam_we = enc_we && (cs_idx_i < 8'(APU_VAM_WORDS));
    assign vam_idx = cs_idx_i[4:0];
    assign vxb_we = enc_we && (cs_idx_i < 8'(APU_VXB_WORDS));
    assign vxb_idx = cs_idx_i[4:0];
    assign vbb_we = enc_we && (cs_idx_i < 8'(APU_VBB_WORDS));
    assign vbb_idx = cs_idx_i[3:0];
    assign vmm_we = enc_we && (cs_idx_i < 8'(APU_VMM_WORDS));
    assign vmm_idx = cs_idx_i[3:0];
    assign vum_we = enc_we && (cs_idx_i < 8'(APU_VUM_WORDS));
    assign vum_idx = cs_idx_i[3:0];
    assign vbm_we = enc_we && (cs_idx_i < 8'(APU_VBM_WORDS));
    assign vbm_idx = cs_idx_i[3:0];
    assign vfm_we = enc_we && (cs_idx_i < 8'(APU_VFM_WORDS));
    assign vfm_idx = cs_idx_i[4:0];
    assign vim_we = enc_we && (cs_idx_i < 8'(APU_VIM_WORDS));
    assign vim_idx = cs_idx_i[4:0];
    assign vmc_we = enc_we && (cs_idx_i < 8'(APU_VMC_WORDS));
    assign vmc_idx = cs_idx_i[3:0];
    assign vdl_we = enc_we && (cs_idx_i < 8'(APU_VDL_WORDS));
    assign vdl_idx = cs_idx_i[4:0];
    assign vpl_we = enc_we && (cs_idx_i < 8'(APU_VPL_WORDS));
    assign vpl_idx = cs_idx_i[4:0];
    assign vcp_we = enc_we && (cs_idx_i < 8'(APU_VCP_WORDS));
    assign vcp_idx = cs_idx_i[4:0];
    assign vda_we = enc_we && (cs_idx_i < 8'(APU_VDA_WORDS));
    assign vda_idx = cs_idx_i[4:0];
    assign vud_we = enc_we && (cs_idx_i < 8'(APU_VUD_WORDS));
    assign vud_idx = cs_idx_i[4:0];
    assign vbp_we = enc_we && (cs_idx_i < 8'(APU_VBP_WORDS));
    assign vbp_idx = cs_idx_i[3:0];
    assign vbd_we = enc_we && (cs_idx_i < 8'(APU_VBD_WORDS));
    assign vbd_idx = cs_idx_i[4:0];
    assign vpo_we = enc_we && (cs_idx_i < 8'(APU_VPO_WORDS));
    assign vpo_idx = cs_idx_i[4:0];
    assign vxi_we = enc_we && (cs_idx_i < 8'(APU_VXI_WORDS));
    assign vxi_idx = cs_idx_i[4:0];
    assign vbi_we = enc_we && (cs_idx_i < 8'(APU_VBI_WORDS));
    assign vbi_idx = cs_idx_i[3:0];
    assign vmi_we = enc_we && (cs_idx_i < 8'(APU_VMI_WORDS));
    assign vmi_idx = cs_idx_i[3:0];
    assign vxv_we = enc_we && (cs_idx_i < 8'(APU_VXV_WORDS));
    assign vxv_idx = cs_idx_i[4:0];
    assign vsm_we = enc_we && (cs_idx_i < 8'(APU_VSM_WORDS));
    assign vsm_idx = cs_idx_i[4:0];
    assign vrp_we = enc_we && (cs_idx_i < 8'(APU_VRP_WORDS));
    assign vrp_idx = cs_idx_i[4:0];
    assign vgp_we = enc_we && (cs_idx_i < 8'(APU_VGP_WORDS));
    assign vgp_idx = cs_idx_i[4:0];
    assign vfb_we = enc_we && (cs_idx_i < 8'(APU_VFB_WORDS));
    assign vfb_idx = cs_idx_i[4:0];
    assign vrb_we = enc_we && (cs_idx_i < 8'(APU_VRB_WORDS));
    assign vrb_idx = cs_idx_i[4:0];
    assign vdw_we = enc_we && (cs_idx_i < 8'(APU_VDW_WORDS));
    assign vdw_idx = cs_idx_i[3:0];
    assign vre_we = enc_we && (cs_idx_i < 8'(APU_VRE_WORDS));
    assign vre_idx = cs_idx_i[3:0];
    assign vvb_we = enc_we && (cs_idx_i < 8'(APU_VVB_WORDS));
    assign vvb_idx = cs_idx_i[3:0];
    assign vib_we = enc_we && (cs_idx_i < 8'(APU_VIB_WORDS));
    assign vib_idx = cs_idx_i[3:0];
    assign vdi_we = enc_we && (cs_idx_i < 8'(APU_VDI_WORDS));
    assign vdi_idx = cs_idx_i[3:0];
    assign vvp_we = enc_we && (cs_idx_i < 8'(APU_VVP_WORDS));
    assign vvp_idx = cs_idx_i[3:0];
    assign vsi_we = enc_we && (cs_idx_i < 8'(APU_VSI_WORDS));
    assign vsi_idx = cs_idx_i[3:0];
    assign vpb_we = enc_we && (cs_idx_i < 8'(APU_VPB_WORDS));
    assign vpb_idx = cs_idx_i[3:0];
    assign vns_we = enc_we && (cs_idx_i < 8'(APU_VNS_WORDS));
    assign vns_idx = cs_idx_i[3:0];
    assign vdf_we = enc_we && (cs_idx_i < 8'(APU_DFB_WORDS));
    assign vdf_idx = cs_idx_i[3:0];
    assign vdx_we = enc_we && (cs_idx_i < 8'(APU_DVW_WORDS));
    assign vdx_idx = cs_idx_i[3:0];
    assign vdk_we = enc_we && (cs_idx_i < 8'(APU_DSM_WORDS));
    assign vdk_idx = cs_idx_i[3:0];
    assign vdr_we = enc_we && (cs_idx_i < 8'(APU_DRP_WORDS));
    assign vdr_idx = cs_idx_i[3:0];
    assign vdb_we = enc_we && (cs_idx_i < 8'(APU_DBF_WORDS));
    assign vdb_idx = cs_idx_i[3:0];
    assign vdg_we = enc_we && (cs_idx_i < 8'(APU_DIM_WORDS));
    assign vdg_idx = cs_idx_i[3:0];
    assign vfe_we = enc_we && (cs_idx_i < 8'(APU_FME_WORDS));
    assign vfe_idx = cs_idx_i[3:0];
    assign vdm_we = enc_we && (cs_idx_i < 8'(APU_DMD_WORDS));
    assign vdm_idx = cs_idx_i[3:0];
    assign vdp_we = enc_we && (cs_idx_i < 8'(APU_DPL_WORDS));
    assign vdp_idx = cs_idx_i[3:0];
    assign vdy_we = enc_we && (cs_idx_i < 8'(APU_DYO_WORDS));
    assign vdy_idx = cs_idx_i[3:0];
    assign vdt_we = enc_we && (cs_idx_i < 8'(APU_DDS_WORDS));
    assign vdt_idx = cs_idx_i[3:0];
    assign vdq_we = enc_we && (cs_idx_i < 8'(APU_DPO_WORDS));
    assign vdq_idx = cs_idx_i[3:0];
    assign vfs_we = enc_we && (cs_idx_i < 8'(APU_FDS_WORDS));
    assign vfs_idx = cs_idx_i[3:0];
    assign vrc_we = enc_we && (cs_idx_i < 8'(APU_RCB_WORDS));
    assign vrc_idx = cs_idx_i[3:0];
    assign vfc_we = enc_we && (cs_idx_i < 8'(APU_FCB_WORDS));
    assign vfc_idx = cs_idx_i[3:0];
    assign vdd_we = enc_we && (cs_idx_i < 8'(APU_DDV_WORDS));
    assign vdd_idx = cs_idx_i[3:0];
    assign vpc_we = enc_we && (cs_idx_i < 8'(APU_RCP_WORDS));
    assign vpc_idx = cs_idx_i[3:0];
    assign vdc_we = enc_we && (cs_idx_i < 8'(APU_DCP_WORDS));
    assign vdc_idx = cs_idx_i[3:0];
    assign vdn_we = enc_we && (cs_idx_i < 8'(APU_DIN_WORDS));
    assign vdn_idx = cs_idx_i[3:0];
    assign vgf_we = enc_we && (cs_idx_i < 8'(APU_GFP_WORDS));
    assign vgf_idx = cs_idx_i[3:0];
    assign vip_we = enc_we && (cs_idx_i < 8'(APU_IFP_WORDS));
    assign vip_idx = cs_idx_i[3:0];
    assign vxe_we = enc_we && (cs_idx_i < 8'(APU_DEX_WORDS));
    assign vxe_idx = cs_idx_i[3:0];
    assign vrd_we = enc_we && (cs_idx_i < 8'(APU_RDP_WORDS));
    assign vrd_idx = cs_idx_i[3:0];
    assign vie_we = enc_we && (cs_idx_i < 8'(APU_IEX_WORDS));
    assign vie_idx = cs_idx_i[3:0];
    assign vwl_we = enc_we && (cs_idx_i < 8'(APU_DWI_WORDS));
    assign vwl_idx = cs_idx_i[3:0];
    assign vsl_we = enc_we && (cs_idx_i < 8'(APU_ISL_WORDS));
    assign vsl_idx = cs_idx_i[3:0];
    assign vrg_we = enc_we && (cs_idx_i < 8'(APU_RAG_WORDS));
    assign vrg_idx = cs_idx_i[3:0];
    assign vlw_we = enc_we && (cs_idx_i < 8'(APU_SLW_WORDS));
    assign vlw_idx = cs_idx_i[3:0];
    assign vzb_we = enc_we && (cs_idx_i < 8'(APU_SDB_WORDS));
    assign vzb_idx = cs_idx_i[3:0];
    assign vbc_we = enc_we && (cs_idx_i < 8'(APU_SBC_WORDS));
    assign vbc_idx = cs_idx_i[3:0];
    assign vbo_we = enc_we && (cs_idx_i < 8'(APU_SBB_WORDS));
    assign vbo_idx = cs_idx_i[3:0];
    assign vcm_we = enc_we && (cs_idx_i < 8'(APU_SCM_WORDS));
    assign vcm_idx = cs_idx_i[3:0];
    assign vwm_we = enc_we && (cs_idx_i < 8'(APU_SWM_WORDS));
    assign vwm_idx = cs_idx_i[3:0];
    assign vrf_we = enc_we && (cs_idx_i < 8'(APU_SRF_WORDS));
    assign vrf_idx = cs_idx_i[3:0];
    assign vcc_we = enc_we && (cs_idx_i < 8'(APU_CCB_WORDS));
    assign vcc_idx = cs_idx_i[3:0];
    assign vcy_we = enc_we && (cs_idx_i < 8'(APU_CCI_WORDS));
    assign vcy_idx = cs_idx_i[4:0];
    assign vbl_we = enc_we && (cs_idx_i < 8'(APU_BLI_WORDS));
    assign vbl_idx = cs_idx_i[4:0];
    assign vbt_we = enc_we && (cs_idx_i < 8'(APU_CBI_WORDS));
    assign vbt_idx = cs_idx_i[4:0];
    assign vic_we = enc_we && (cs_idx_i < 8'(APU_CIB_WORDS));
    assign vic_idx = cs_idx_i[4:0];
    assign vub_we = enc_we && (cs_idx_i < 8'(APU_UBF_WORDS));
    assign vub_idx = cs_idx_i[3:0];
    assign vfl_we = enc_we && (cs_idx_i < 8'(APU_FIL_WORDS));
    assign vfl_idx = cs_idx_i[3:0];
    assign vcl_we = enc_we && (cs_idx_i < 8'(APU_CCL_WORDS));
    assign vcl_idx = cs_idx_i[4:0];
    assign vio_we = enc_we && (cs_idx_i < 8'(APU_DRI_WORDS));
    assign vio_idx = cs_idx_i[3:0];
    assign vix_we = enc_we && (cs_idx_i < 8'(APU_IXI_WORDS));
    assign vix_idx = cs_idx_i[3:0];
    assign vds_we = enc_we && (cs_idx_i < 8'(APU_CDS_WORDS));
    assign vds_idx = cs_idx_i[4:0];
    assign vat_we = enc_we && (cs_idx_i < 8'(APU_CAT_WORDS));
    assign vat_idx = cs_idx_i[4:0];
    assign vin_we = enc_we && (cs_idx_i < 8'(APU_DSI_WORDS));
    assign vin_idx = cs_idx_i[3:0];
    assign vrs_we = enc_we && (cs_idx_i < 8'(APU_RSI_WORDS));
    assign vrs_idx = cs_idx_i[4:0];
    assign vgs_we = enc_we && (cs_idx_i < 8'(APU_GFS_WORDS));
    assign vgs_idx = cs_idx_i[3:0];
    assign vwf_we = enc_we && (cs_idx_i < 8'(APU_WFE_WORDS));
    assign vwf_idx = cs_idx_i[3:0];
    assign vfr_we = enc_we && (cs_idx_i < 8'(APU_RFE_WORDS));
    assign vfr_idx = cs_idx_i[3:0];
    assign vfn_we = enc_we && (cs_idx_i < 8'(APU_DFE_WORDS));
    assign vfn_idx = cs_idx_i[3:0];
    assign enc_req = state_q == FireEnc;
    assign enc_ack = state_q == WaitEnc;
    assign vnd_req = state_q == FireVnd;
    assign vnd_ack = state_q == WaitVnd;
    assign vbg_req = state_q == FireVbg;
    assign vbg_ack = state_q == WaitVbg;
    assign ven_req = state_q == FireVen;
    assign ven_ack = state_q == WaitVen;
    assign vqs_req = state_q == FireVqs;
    assign vqs_ack = state_q == WaitVqs;
    assign vwi_req = state_q == FireVwi;
    assign vwi_ack = state_q == WaitVwi;
    assign vgq_req = state_q == FireVgq;
    assign vgq_ack = state_q == WaitVgq;
    assign vcd_req = state_q == FireVcd;
    assign vcd_ack = state_q == WaitVcd;
    assign vci_req = state_q == FireVci;
    assign vci_ack = state_q == WaitVci;
    assign vep_req = state_q == FireVep;
    assign vep_ack = state_q == WaitVep;
    assign vqf_req = state_q == FireVqf;
    assign vqf_ack = state_q == WaitVqf;
    assign vpf_req = state_q == FireVpf;
    assign vpf_ack = state_q == WaitVpf;
    assign vpp_req = state_q == FireVpp;
    assign vpp_ack = state_q == WaitVpp;
    assign vmp_req = state_q == FireVmp;
    assign vmp_ack = state_q == WaitVmp;
    assign vam_req = state_q == FireVam;
    assign vam_ack = state_q == WaitVam;
    assign vxb_req = state_q == FireVxb;
    assign vxb_ack = state_q == WaitVxb;
    assign vbb_req = state_q == FireVbb;
    assign vbb_ack = state_q == WaitVbb;
    assign vmm_req = state_q == FireVmm;
    assign vmm_ack = state_q == WaitVmm;
    assign vum_req = state_q == FireVum;
    assign vum_ack = state_q == WaitVum;
    assign vbm_req = state_q == FireVbm;
    assign vbm_ack = state_q == WaitVbm;
    assign vfm_req = state_q == FireVfm;
    assign vfm_ack = state_q == WaitVfm;
    assign vim_req = state_q == FireVim;
    assign vim_ack = state_q == WaitVim;
    assign vmc_req = state_q == FireVmc;
    assign vmc_ack = state_q == WaitVmc;
    assign vdl_req = state_q == FireVdl;
    assign vdl_ack = state_q == WaitVdl;
    assign vpl_req = state_q == FireVpl;
    assign vpl_ack = state_q == WaitVpl;
    assign vcp_req = state_q == FireVcp;
    assign vcp_ack = state_q == WaitVcp;
    assign vda_req = state_q == FireVda;
    assign vda_ack = state_q == WaitVda;
    assign vud_req = state_q == FireVud;
    assign vud_ack = state_q == WaitVud;
    assign vbp_req = state_q == FireVbp;
    assign vbp_ack = state_q == WaitVbp;
    assign vbd_req = state_q == FireVbd;
    assign vbd_ack = state_q == WaitVbd;
    assign vpo_req = state_q == FireVpo;
    assign vpo_ack = state_q == WaitVpo;
    assign vxi_req = state_q == FireVxi;
    assign vxi_ack = state_q == WaitVxi;
    assign vbi_req = state_q == FireVbi;
    assign vbi_ack = state_q == WaitVbi;
    assign vmi_req = state_q == FireVmi;
    assign vmi_ack = state_q == WaitVmi;
    assign vxv_req = state_q == FireVxv;
    assign vxv_ack = state_q == WaitVxv;
    assign vsm_req = state_q == FireVsm;
    assign vsm_ack = state_q == WaitVsm;
    assign vrp_req = state_q == FireVrp;
    assign vrp_ack = state_q == WaitVrp;
    assign vgp_req = state_q == FireVgp;
    assign vgp_ack = state_q == WaitVgp;
    assign vfb_req = state_q == FireVfb;
    assign vfb_ack = state_q == WaitVfb;
    assign vrb_req = state_q == FireVrb;
    assign vrb_ack = state_q == WaitVrb;
    assign vdw_req = state_q == FireVdw;
    assign vdw_ack = state_q == WaitVdw;
    assign vre_req = state_q == FireVre;
    assign vre_ack = state_q == WaitVre;
    assign vvb_req = state_q == FireVvb;
    assign vvb_ack = state_q == WaitVvb;
    assign vib_req = state_q == FireVib;
    assign vib_ack = state_q == WaitVib;
    assign vdi_req = state_q == FireVdi;
    assign vdi_ack = state_q == WaitVdi;
    assign vvp_req = state_q == FireVvp;
    assign vvp_ack = state_q == WaitVvp;
    assign vsi_req = state_q == FireVsi;
    assign vsi_ack = state_q == WaitVsi;
    assign vpb_req = state_q == FireVpb;
    assign vpb_ack = state_q == WaitVpb;
    assign vns_req = state_q == FireVns;
    assign vns_ack = state_q == WaitVns;
    assign vdf_req = state_q == FireVdf;
    assign vdf_ack = state_q == WaitVdf;
    assign vdx_req = state_q == FireVdx;
    assign vdx_ack = state_q == WaitVdx;
    assign vdk_req = state_q == FireVdk;
    assign vdk_ack = state_q == WaitVdk;
    assign vdr_req = state_q == FireVdr;
    assign vdr_ack = state_q == WaitVdr;
    assign vdb_req = state_q == FireVdb;
    assign vdb_ack = state_q == WaitVdb;
    assign vdg_req = state_q == FireVdg;
    assign vdg_ack = state_q == WaitVdg;
    assign vfe_req = state_q == FireVfe;
    assign vfe_ack = state_q == WaitVfe;
    assign vdm_req = state_q == FireVdm;
    assign vdm_ack = state_q == WaitVdm;
    assign vdp_req = state_q == FireVdp;
    assign vdp_ack = state_q == WaitVdp;
    assign vdy_req = state_q == FireVdy;
    assign vdy_ack = state_q == WaitVdy;
    assign vdt_req = state_q == FireVdt;
    assign vdt_ack = state_q == WaitVdt;
    assign vdq_req = state_q == FireVdq;
    assign vdq_ack = state_q == WaitVdq;
    assign vfs_req = state_q == FireVfs;
    assign vfs_ack = state_q == WaitVfs;
    assign vrc_req = state_q == FireVrc;
    assign vrc_ack = state_q == WaitVrc;
    assign vfc_req = state_q == FireVfc;
    assign vfc_ack = state_q == WaitVfc;
    assign vdd_req = state_q == FireVdd;
    assign vdd_ack = state_q == WaitVdd;
    assign vpc_req = state_q == FireVpc;
    assign vpc_ack = state_q == WaitVpc;
    assign vdc_req = state_q == FireVdc;
    assign vdc_ack = state_q == WaitVdc;
    assign vdn_req = state_q == FireVdn;
    assign vdn_ack = state_q == WaitVdn;
    assign vgf_req = state_q == FireVgf;
    assign vgf_ack = state_q == WaitVgf;
    assign vip_req = state_q == FireVip;
    assign vip_ack = state_q == WaitVip;
    assign vxe_req = state_q == FireVxe;
    assign vxe_ack = state_q == WaitVxe;
    assign vrd_req = state_q == FireVrd;
    assign vrd_ack = state_q == WaitVrd;
    assign vie_req = state_q == FireVie;
    assign vie_ack = state_q == WaitVie;
    assign vwl_req = state_q == FireVwl;
    assign vwl_ack = state_q == WaitVwl;
    assign vsl_req = state_q == FireVsl;
    assign vsl_ack = state_q == WaitVsl;
    assign vrg_req = state_q == FireVrg;
    assign vrg_ack = state_q == WaitVrg;
    assign vlw_req = state_q == FireVlw;
    assign vlw_ack = state_q == WaitVlw;
    assign vzb_req = state_q == FireVzb;
    assign vzb_ack = state_q == WaitVzb;
    assign vbc_req = state_q == FireVbc;
    assign vbc_ack = state_q == WaitVbc;
    assign vbo_req = state_q == FireVbo;
    assign vbo_ack = state_q == WaitVbo;
    assign vcm_req = state_q == FireVcm;
    assign vcm_ack = state_q == WaitVcm;
    assign vwm_req = state_q == FireVwm;
    assign vwm_ack = state_q == WaitVwm;
    assign vrf_req = state_q == FireVrf;
    assign vrf_ack = state_q == WaitVrf;
    assign vcc_req = state_q == FireVcc;
    assign vcc_ack = state_q == WaitVcc;
    assign vcy_req = state_q == FireVcy;
    assign vcy_ack = state_q == WaitVcy;
    assign vbl_req = state_q == FireVbl;
    assign vbl_ack = state_q == WaitVbl;
    assign vbt_req = state_q == FireVbt;
    assign vbt_ack = state_q == WaitVbt;
    assign vic_req = state_q == FireVic;
    assign vic_ack = state_q == WaitVic;
    assign vub_req = state_q == FireVub;
    assign vub_ack = state_q == WaitVub;
    assign vfl_req = state_q == FireVfl;
    assign vfl_ack = state_q == WaitVfl;
    assign vcl_req = state_q == FireVcl;
    assign vcl_ack = state_q == WaitVcl;
    assign vio_req = state_q == FireVio;
    assign vio_ack = state_q == WaitVio;
    assign vix_req = state_q == FireVix;
    assign vix_ack = state_q == WaitVix;
    assign vds_req = state_q == FireVds;
    assign vds_ack = state_q == WaitVds;
    assign vat_req = state_q == FireVat;
    assign vat_ack = state_q == WaitVat;
    assign vin_req = state_q == FireVin;
    assign vin_ack = state_q == WaitVin;
    assign vrs_req = state_q == FireVrs;
    assign vrs_ack = state_q == WaitVrs;
    assign vgs_req = state_q == FireVgs;
    assign vgs_ack = state_q == WaitVgs;
    assign vwf_req = state_q == FireVwf;
    assign vwf_ack = state_q == WaitVwf;
    assign vfr_req = state_q == FireVfr;
    assign vfr_ack = state_q == WaitVfr;
    assign vfn_req = state_q == FireVfn;
    assign vfn_ack = state_q == WaitVfn;
    assign gnh_req_v = state_q == FireGnh;
    assign gnh_ack = state_q == WaitGnh;
    assign spv_we = state_q == Load;
    assign spv_idx = load_q[6:0];
    assign spv_wdata = enc_rdata;
    assign spv_len = n_q;
    assign spv_commit = state_q == Commit;
    assign spv_start = state_q == Kick;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign pool = {cs_q[10], cs_q[9]};
    assign level = cs_q[11];
    assign count = cs_q[12];
    assign asz = {cs_q[14], cs_q[13]};
    assign guest = {cs_q[16], cs_q[15]};
    assign want_reply = flags == APU_VAC_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VAC_CMD_ALLOC) &&
                       ((flags == 32'd0) || (flags == APU_VAC_GENERATE_REPLY)) &&
                       (pinfo != 64'd0) &&
                       (stype == APU_VAC_STYPE_ALLOC) &&
                       (pnext == 64'd0) &&
                       (pool != 64'd0) &&
                       (level == APU_VAC_LEVEL_PRIMARY) &&
                       (count == 32'd1) &&
                       (asz == 64'd1) &&
                       (guest[63:32] == 32'd0) &&
                       (guest[31:0] != 32'd0);

    g6lc_apu_vnenc #(.Enable(1'b1)) i_enc (
      .clk_i, .rst_ni, .cs_we_i(enc_we), .cs_idx_i(enc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(enc_rdata),
      .req_valid_i(enc_req), .req_ready_o(enc_rdy),
      .cpl_valid_o(enc_cpl), .cpl_ready_i(enc_ack), .cpl_o(enc_c),
      .vnenc_o(enc_rec)
    );
    g6lc_apu_vnd #(.Enable(1'b1)) i_vnd (
      .clk_i, .rst_ni, .cs_we_i(vnd_we), .cs_idx_i(vnd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vnd_rdata),
      .req_valid_i(vnd_req), .req_ready_o(vnd_rdy),
      .cpl_valid_o(vnd_cpl), .cpl_ready_i(vnd_ack), .cpl_o(vnd_c),
      .vnd_o(vnd_rec)
    );
    g6lc_apu_vbg #(.Enable(1'b1)) i_vbg (
      .clk_i, .rst_ni, .cs_we_i(vbg_we), .cs_idx_i(vbg_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbg_rdata),
      .req_valid_i(vbg_req), .req_ready_o(vbg_rdy),
      .cpl_valid_o(vbg_cpl), .cpl_ready_i(vbg_ack), .cpl_o(vbg_c), .vbg_o(vbg_rec)
    );
    g6lc_apu_ven #(.Enable(1'b1)) i_ven (
      .clk_i, .rst_ni, .cs_we_i(ven_we), .cs_idx_i(ven_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(ven_rdata),
      .req_valid_i(ven_req), .req_ready_o(ven_rdy),
      .cpl_valid_o(ven_cpl), .cpl_ready_i(ven_ack), .cpl_o(ven_c), .ven_o(ven_rec)
    );
    g6lc_apu_vqs #(.Enable(1'b1)) i_vqs (
      .clk_i, .rst_ni, .cs_we_i(vqs_we), .cs_idx_i(vqs_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vqs_rdata),
      .req_valid_i(vqs_req), .req_ready_o(vqs_rdy),
      .cpl_valid_o(vqs_cpl), .cpl_ready_i(vqs_ack), .cpl_o(vqs_c), .vqs_o(vqs_rec)
    );
    g6lc_apu_vwi #(.Enable(1'b1)) i_vwi (
      .clk_i, .rst_ni, .cs_we_i(vwi_we), .cs_idx_i(vwi_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vwi_rdata),
      .req_valid_i(vwi_req), .req_ready_o(vwi_rdy),
      .cpl_valid_o(vwi_cpl), .cpl_ready_i(vwi_ack), .cpl_o(vwi_c), .vwi_o(vwi_rec)
    );
    g6lc_apu_vgq #(.Enable(1'b1)) i_vgq (
      .clk_i, .rst_ni, .cs_we_i(vgq_we), .cs_idx_i(vgq_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vgq_rdata),
      .req_valid_i(vgq_req), .req_ready_o(vgq_rdy),
      .cpl_valid_o(vgq_cpl), .cpl_ready_i(vgq_ack), .cpl_o(vgq_c), .vgq_o(vgq_rec)
    );
    g6lc_apu_vcd #(.Enable(1'b1)) i_vcd (
      .clk_i, .rst_ni, .cs_we_i(vcd_we), .cs_idx_i(vcd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vcd_rdata),
      .req_valid_i(vcd_req), .req_ready_o(vcd_rdy),
      .cpl_valid_o(vcd_cpl), .cpl_ready_i(vcd_ack), .cpl_o(vcd_c), .vcd_o(vcd_rec)
    );
    g6lc_apu_vci #(.Enable(1'b1)) i_vci (
      .clk_i, .rst_ni, .cs_we_i(vci_we), .cs_idx_i(vci_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vci_rdata),
      .req_valid_i(vci_req), .req_ready_o(vci_rdy),
      .cpl_valid_o(vci_cpl), .cpl_ready_i(vci_ack), .cpl_o(vci_c), .vci_o(vci_rec)
    );
    g6lc_apu_vep #(.Enable(1'b1)) i_vep (
      .clk_i, .rst_ni, .cs_we_i(vep_we), .cs_idx_i(vep_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vep_rdata),
      .req_valid_i(vep_req), .req_ready_o(vep_rdy),
      .cpl_valid_o(vep_cpl), .cpl_ready_i(vep_ack), .cpl_o(vep_c), .vep_o(vep_rec)
    );
    g6lc_apu_vqf #(.Enable(1'b1)) i_vqf (
      .clk_i, .rst_ni, .cs_we_i(vqf_we), .cs_idx_i(vqf_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vqf_rdata),
      .req_valid_i(vqf_req), .req_ready_o(vqf_rdy),
      .cpl_valid_o(vqf_cpl), .cpl_ready_i(vqf_ack), .cpl_o(vqf_c), .vqf_o(vqf_rec)
    );
    g6lc_apu_vpf #(.Enable(1'b1)) i_vpf (
      .clk_i, .rst_ni, .cs_we_i(vpf_we), .cs_idx_i(vpf_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vpf_rdata),
      .req_valid_i(vpf_req), .req_ready_o(vpf_rdy),
      .cpl_valid_o(vpf_cpl), .cpl_ready_i(vpf_ack), .cpl_o(vpf_c), .vpf_o(vpf_rec)
    );
    g6lc_apu_vpp #(.Enable(1'b1)) i_vpp (
      .clk_i, .rst_ni, .cs_we_i(vpp_we), .cs_idx_i(vpp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vpp_rdata),
      .req_valid_i(vpp_req), .req_ready_o(vpp_rdy),
      .cpl_valid_o(vpp_cpl), .cpl_ready_i(vpp_ack), .cpl_o(vpp_c), .vpp_o(vpp_rec)
    );
    g6lc_apu_vmp #(.Enable(1'b1)) i_vmp (
      .clk_i, .rst_ni, .cs_we_i(vmp_we), .cs_idx_i(vmp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vmp_rdata),
      .req_valid_i(vmp_req), .req_ready_o(vmp_rdy),
      .cpl_valid_o(vmp_cpl), .cpl_ready_i(vmp_ack), .cpl_o(vmp_c), .vmp_o(vmp_rec)
    );
    g6lc_apu_vam #(.Enable(1'b1)) i_vam (
      .clk_i, .rst_ni, .cs_we_i(vam_we), .cs_idx_i(vam_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vam_rdata),
      .req_valid_i(vam_req), .req_ready_o(vam_rdy),
      .cpl_valid_o(vam_cpl), .cpl_ready_i(vam_ack), .cpl_o(vam_c), .vam_o(vam_rec)
    );
    g6lc_apu_vxb #(.Enable(1'b1)) i_vxb (
      .clk_i, .rst_ni, .cs_we_i(vxb_we), .cs_idx_i(vxb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vxb_rdata),
      .req_valid_i(vxb_req), .req_ready_o(vxb_rdy),
      .cpl_valid_o(vxb_cpl), .cpl_ready_i(vxb_ack), .cpl_o(vxb_c), .vxb_o(vxb_rec)
    );
    g6lc_apu_vbb #(.Enable(1'b1)) i_vbb (
      .clk_i, .rst_ni, .cs_we_i(vbb_we), .cs_idx_i(vbb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbb_rdata),
      .req_valid_i(vbb_req), .req_ready_o(vbb_rdy),
      .cpl_valid_o(vbb_cpl), .cpl_ready_i(vbb_ack), .cpl_o(vbb_c), .vbb_o(vbb_rec)
    );
    g6lc_apu_vmm #(.Enable(1'b1)) i_vmm (
      .clk_i, .rst_ni, .cs_we_i(vmm_we), .cs_idx_i(vmm_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vmm_rdata),
      .req_valid_i(vmm_req), .req_ready_o(vmm_rdy),
      .cpl_valid_o(vmm_cpl), .cpl_ready_i(vmm_ack), .cpl_o(vmm_c), .vmm_o(vmm_rec)
    );
    g6lc_apu_vum #(.Enable(1'b1)) i_vum (
      .clk_i, .rst_ni, .cs_we_i(vum_we), .cs_idx_i(vum_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vum_rdata),
      .req_valid_i(vum_req), .req_ready_o(vum_rdy),
      .cpl_valid_o(vum_cpl), .cpl_ready_i(vum_ack), .cpl_o(vum_c), .vum_o(vum_rec)
    );
    g6lc_apu_vbm #(.Enable(1'b1)) i_vbm (
      .clk_i, .rst_ni, .cs_we_i(vbm_we), .cs_idx_i(vbm_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbm_rdata),
      .req_valid_i(vbm_req), .req_ready_o(vbm_rdy),
      .cpl_valid_o(vbm_cpl), .cpl_ready_i(vbm_ack), .cpl_o(vbm_c), .vbm_o(vbm_rec)
    );
    g6lc_apu_vfm #(.Enable(1'b1)) i_vfm (
      .clk_i, .rst_ni, .cs_we_i(vfm_we), .cs_idx_i(vfm_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfm_rdata),
      .req_valid_i(vfm_req), .req_ready_o(vfm_rdy),
      .cpl_valid_o(vfm_cpl), .cpl_ready_i(vfm_ack), .cpl_o(vfm_c), .vfm_o(vfm_rec)
    );
    g6lc_apu_vim #(.Enable(1'b1)) i_vim (
      .clk_i, .rst_ni, .cs_we_i(vim_we), .cs_idx_i(vim_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vim_rdata),
      .req_valid_i(vim_req), .req_ready_o(vim_rdy),
      .cpl_valid_o(vim_cpl), .cpl_ready_i(vim_ack), .cpl_o(vim_c), .vim_o(vim_rec)
    );
    g6lc_apu_vmc #(.Enable(1'b1)) i_vmc (
      .clk_i, .rst_ni, .cs_we_i(vmc_we), .cs_idx_i(vmc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vmc_rdata),
      .req_valid_i(vmc_req), .req_ready_o(vmc_rdy),
      .cpl_valid_o(vmc_cpl), .cpl_ready_i(vmc_ack), .cpl_o(vmc_c), .vmc_o(vmc_rec)
    );
    g6lc_apu_vdl #(.Enable(1'b1)) i_vdl (
      .clk_i, .rst_ni, .cs_we_i(vdl_we), .cs_idx_i(vdl_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdl_rdata),
      .req_valid_i(vdl_req), .req_ready_o(vdl_rdy),
      .cpl_valid_o(vdl_cpl), .cpl_ready_i(vdl_ack), .cpl_o(vdl_c), .vdl_o(vdl_rec)
    );
    g6lc_apu_vpl #(.Enable(1'b1)) i_vpl (
      .clk_i, .rst_ni, .cs_we_i(vpl_we), .cs_idx_i(vpl_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vpl_rdata),
      .req_valid_i(vpl_req), .req_ready_o(vpl_rdy),
      .cpl_valid_o(vpl_cpl), .cpl_ready_i(vpl_ack), .cpl_o(vpl_c), .vpl_o(vpl_rec)
    );
    g6lc_apu_vcp #(.Enable(1'b1)) i_vcp (
      .clk_i, .rst_ni, .cs_we_i(vcp_we), .cs_idx_i(vcp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vcp_rdata),
      .req_valid_i(vcp_req), .req_ready_o(vcp_rdy),
      .cpl_valid_o(vcp_cpl), .cpl_ready_i(vcp_ack), .cpl_o(vcp_c), .vcp_o(vcp_rec)
    );
    g6lc_apu_vda #(.Enable(1'b1)) i_vda (
      .clk_i, .rst_ni, .cs_we_i(vda_we), .cs_idx_i(vda_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vda_rdata),
      .req_valid_i(vda_req), .req_ready_o(vda_rdy),
      .cpl_valid_o(vda_cpl), .cpl_ready_i(vda_ack), .cpl_o(vda_c), .vda_o(vda_rec)
    );
    g6lc_apu_vud #(.Enable(1'b1)) i_vud (
      .clk_i, .rst_ni, .cs_we_i(vud_we), .cs_idx_i(vud_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vud_rdata),
      .req_valid_i(vud_req), .req_ready_o(vud_rdy),
      .cpl_valid_o(vud_cpl), .cpl_ready_i(vud_ack), .cpl_o(vud_c), .vud_o(vud_rec)
    );
    g6lc_apu_vbp #(.Enable(1'b1)) i_vbp (
      .clk_i, .rst_ni, .cs_we_i(vbp_we), .cs_idx_i(vbp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbp_rdata),
      .req_valid_i(vbp_req), .req_ready_o(vbp_rdy),
      .cpl_valid_o(vbp_cpl), .cpl_ready_i(vbp_ack), .cpl_o(vbp_c), .vbp_o(vbp_rec)
    );
    g6lc_apu_vbd #(.Enable(1'b1)) i_vbd (
      .clk_i, .rst_ni, .cs_we_i(vbd_we), .cs_idx_i(vbd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbd_rdata),
      .req_valid_i(vbd_req), .req_ready_o(vbd_rdy),
      .cpl_valid_o(vbd_cpl), .cpl_ready_i(vbd_ack), .cpl_o(vbd_c), .vbd_o(vbd_rec)
    );
    g6lc_apu_vpo #(.Enable(1'b1)) i_vpo (
      .clk_i, .rst_ni, .cs_we_i(vpo_we), .cs_idx_i(vpo_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vpo_rdata),
      .req_valid_i(vpo_req), .req_ready_o(vpo_rdy),
      .cpl_valid_o(vpo_cpl), .cpl_ready_i(vpo_ack), .cpl_o(vpo_c), .vpo_o(vpo_rec)
    );
    g6lc_apu_vxi #(.Enable(1'b1)) i_vxi (
      .clk_i, .rst_ni, .cs_we_i(vxi_we), .cs_idx_i(vxi_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vxi_rdata),
      .req_valid_i(vxi_req), .req_ready_o(vxi_rdy),
      .cpl_valid_o(vxi_cpl), .cpl_ready_i(vxi_ack), .cpl_o(vxi_c), .vxi_o(vxi_rec)
    );
    g6lc_apu_vbi #(.Enable(1'b1)) i_vbi (
      .clk_i, .rst_ni, .cs_we_i(vbi_we), .cs_idx_i(vbi_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbi_rdata),
      .req_valid_i(vbi_req), .req_ready_o(vbi_rdy),
      .cpl_valid_o(vbi_cpl), .cpl_ready_i(vbi_ack), .cpl_o(vbi_c), .vbi_o(vbi_rec)
    );
    g6lc_apu_vmi #(.Enable(1'b1)) i_vmi (
      .clk_i, .rst_ni, .cs_we_i(vmi_we), .cs_idx_i(vmi_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vmi_rdata),
      .req_valid_i(vmi_req), .req_ready_o(vmi_rdy),
      .cpl_valid_o(vmi_cpl), .cpl_ready_i(vmi_ack), .cpl_o(vmi_c), .vmi_o(vmi_rec)
    );
    g6lc_apu_vxv #(.Enable(1'b1)) i_vxv (
      .clk_i, .rst_ni, .cs_we_i(vxv_we), .cs_idx_i(vxv_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vxv_rdata),
      .req_valid_i(vxv_req), .req_ready_o(vxv_rdy),
      .cpl_valid_o(vxv_cpl), .cpl_ready_i(vxv_ack), .cpl_o(vxv_c), .vxv_o(vxv_rec)
    );
    g6lc_apu_vsm #(.Enable(1'b1)) i_vsm (
      .clk_i, .rst_ni, .cs_we_i(vsm_we), .cs_idx_i(vsm_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vsm_rdata),
      .req_valid_i(vsm_req), .req_ready_o(vsm_rdy),
      .cpl_valid_o(vsm_cpl), .cpl_ready_i(vsm_ack), .cpl_o(vsm_c), .vsm_o(vsm_rec)
    );
    g6lc_apu_vrp #(.Enable(1'b1)) i_vrp (
      .clk_i, .rst_ni, .cs_we_i(vrp_we), .cs_idx_i(vrp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vrp_rdata),
      .req_valid_i(vrp_req), .req_ready_o(vrp_rdy),
      .cpl_valid_o(vrp_cpl), .cpl_ready_i(vrp_ack), .cpl_o(vrp_c), .vrp_o(vrp_rec)
    );
    g6lc_apu_vgp #(.Enable(1'b1)) i_vgp (
      .clk_i, .rst_ni, .cs_we_i(vgp_we), .cs_idx_i(vgp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vgp_rdata),
      .req_valid_i(vgp_req), .req_ready_o(vgp_rdy),
      .cpl_valid_o(vgp_cpl), .cpl_ready_i(vgp_ack), .cpl_o(vgp_c), .vgp_o(vgp_rec)
    );
    g6lc_apu_vfb #(.Enable(1'b1)) i_vfb (
      .clk_i, .rst_ni, .cs_we_i(vfb_we), .cs_idx_i(vfb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfb_rdata),
      .req_valid_i(vfb_req), .req_ready_o(vfb_rdy),
      .cpl_valid_o(vfb_cpl), .cpl_ready_i(vfb_ack), .cpl_o(vfb_c), .vfb_o(vfb_rec)
    );
    g6lc_apu_vrb #(.Enable(1'b1)) i_vrb (
      .clk_i, .rst_ni, .cs_we_i(vrb_we), .cs_idx_i(vrb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vrb_rdata),
      .req_valid_i(vrb_req), .req_ready_o(vrb_rdy),
      .cpl_valid_o(vrb_cpl), .cpl_ready_i(vrb_ack), .cpl_o(vrb_c), .vrb_o(vrb_rec)
    );
    g6lc_apu_vdw #(.Enable(1'b1)) i_vdw (
      .clk_i, .rst_ni, .cs_we_i(vdw_we), .cs_idx_i(vdw_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdw_rdata),
      .req_valid_i(vdw_req), .req_ready_o(vdw_rdy),
      .cpl_valid_o(vdw_cpl), .cpl_ready_i(vdw_ack), .cpl_o(vdw_c), .vdw_o(vdw_rec)
    );
    g6lc_apu_vre #(.Enable(1'b1)) i_vre (
      .clk_i, .rst_ni, .cs_we_i(vre_we), .cs_idx_i(vre_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vre_rdata),
      .req_valid_i(vre_req), .req_ready_o(vre_rdy),
      .cpl_valid_o(vre_cpl), .cpl_ready_i(vre_ack), .cpl_o(vre_c), .vre_o(vre_rec)
    );
    g6lc_apu_vvb #(.Enable(1'b1)) i_vvb (
      .clk_i, .rst_ni, .cs_we_i(vvb_we), .cs_idx_i(vvb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vvb_rdata),
      .req_valid_i(vvb_req), .req_ready_o(vvb_rdy),
      .cpl_valid_o(vvb_cpl), .cpl_ready_i(vvb_ack), .cpl_o(vvb_c), .vvb_o(vvb_rec)
    );
    g6lc_apu_vib #(.Enable(1'b1)) i_vib (
      .clk_i, .rst_ni, .cs_we_i(vib_we), .cs_idx_i(vib_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vib_rdata),
      .req_valid_i(vib_req), .req_ready_o(vib_rdy),
      .cpl_valid_o(vib_cpl), .cpl_ready_i(vib_ack), .cpl_o(vib_c), .vib_o(vib_rec)
    );
    g6lc_apu_vdi #(.Enable(1'b1)) i_vdi (
      .clk_i, .rst_ni, .cs_we_i(vdi_we), .cs_idx_i(vdi_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdi_rdata),
      .req_valid_i(vdi_req), .req_ready_o(vdi_rdy),
      .cpl_valid_o(vdi_cpl), .cpl_ready_i(vdi_ack), .cpl_o(vdi_c), .vdi_o(vdi_rec)
    );
    g6lc_apu_vvp #(.Enable(1'b1)) i_vvp (
      .clk_i, .rst_ni, .cs_we_i(vvp_we), .cs_idx_i(vvp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vvp_rdata),
      .req_valid_i(vvp_req), .req_ready_o(vvp_rdy),
      .cpl_valid_o(vvp_cpl), .cpl_ready_i(vvp_ack), .cpl_o(vvp_c), .vvp_o(vvp_rec)
    );
    g6lc_apu_vsi #(.Enable(1'b1)) i_vsi (
      .clk_i, .rst_ni, .cs_we_i(vsi_we), .cs_idx_i(vsi_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vsi_rdata),
      .req_valid_i(vsi_req), .req_ready_o(vsi_rdy),
      .cpl_valid_o(vsi_cpl), .cpl_ready_i(vsi_ack), .cpl_o(vsi_c), .vsi_o(vsi_rec)
    );
    g6lc_apu_vpb #(.Enable(1'b1)) i_vpb (
      .clk_i, .rst_ni, .cs_we_i(vpb_we), .cs_idx_i(vpb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vpb_rdata),
      .req_valid_i(vpb_req), .req_ready_o(vpb_rdy),
      .cpl_valid_o(vpb_cpl), .cpl_ready_i(vpb_ack), .cpl_o(vpb_c), .vpb_o(vpb_rec)
    );
    g6lc_apu_vns #(.Enable(1'b1)) i_vns (
      .clk_i, .rst_ni, .cs_we_i(vns_we), .cs_idx_i(vns_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vns_rdata),
      .req_valid_i(vns_req), .req_ready_o(vns_rdy),
      .cpl_valid_o(vns_cpl), .cpl_ready_i(vns_ack), .cpl_o(vns_c), .vns_o(vns_rec)
    );
    g6lc_apu_vdf #(.Enable(1'b1)) i_vdf (
      .clk_i, .rst_ni, .cs_we_i(vdf_we), .cs_idx_i(vdf_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdf_rdata),
      .req_valid_i(vdf_req), .req_ready_o(vdf_rdy),
      .cpl_valid_o(vdf_cpl), .cpl_ready_i(vdf_ack), .cpl_o(vdf_c), .vdf_o(vdf_rec)
    );
    g6lc_apu_vdx #(.Enable(1'b1)) i_vdx (
      .clk_i, .rst_ni, .cs_we_i(vdx_we), .cs_idx_i(vdx_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdx_rdata),
      .req_valid_i(vdx_req), .req_ready_o(vdx_rdy),
      .cpl_valid_o(vdx_cpl), .cpl_ready_i(vdx_ack), .cpl_o(vdx_c), .vdx_o(vdx_rec)
    );
    g6lc_apu_vdk #(.Enable(1'b1)) i_vdk (
      .clk_i, .rst_ni, .cs_we_i(vdk_we), .cs_idx_i(vdk_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdk_rdata),
      .req_valid_i(vdk_req), .req_ready_o(vdk_rdy),
      .cpl_valid_o(vdk_cpl), .cpl_ready_i(vdk_ack), .cpl_o(vdk_c), .vdk_o(vdk_rec)
    );
    g6lc_apu_vdr #(.Enable(1'b1)) i_vdr (
      .clk_i, .rst_ni, .cs_we_i(vdr_we), .cs_idx_i(vdr_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdr_rdata),
      .req_valid_i(vdr_req), .req_ready_o(vdr_rdy),
      .cpl_valid_o(vdr_cpl), .cpl_ready_i(vdr_ack), .cpl_o(vdr_c), .vdr_o(vdr_rec)
    );
    g6lc_apu_vdb #(.Enable(1'b1)) i_vdb (
      .clk_i, .rst_ni, .cs_we_i(vdb_we), .cs_idx_i(vdb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdb_rdata),
      .req_valid_i(vdb_req), .req_ready_o(vdb_rdy),
      .cpl_valid_o(vdb_cpl), .cpl_ready_i(vdb_ack), .cpl_o(vdb_c), .vdb_o(vdb_rec)
    );
    g6lc_apu_vdg #(.Enable(1'b1)) i_vdg (
      .clk_i, .rst_ni, .cs_we_i(vdg_we), .cs_idx_i(vdg_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdg_rdata),
      .req_valid_i(vdg_req), .req_ready_o(vdg_rdy),
      .cpl_valid_o(vdg_cpl), .cpl_ready_i(vdg_ack), .cpl_o(vdg_c), .vdg_o(vdg_rec)
    );
    g6lc_apu_vfe #(.Enable(1'b1)) i_vfe (
      .clk_i, .rst_ni, .cs_we_i(vfe_we), .cs_idx_i(vfe_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfe_rdata),
      .req_valid_i(vfe_req), .req_ready_o(vfe_rdy),
      .cpl_valid_o(vfe_cpl), .cpl_ready_i(vfe_ack), .cpl_o(vfe_c), .vfe_o(vfe_rec)
    );
    g6lc_apu_vdm #(.Enable(1'b1)) i_vdm (
      .clk_i, .rst_ni, .cs_we_i(vdm_we), .cs_idx_i(vdm_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdm_rdata),
      .req_valid_i(vdm_req), .req_ready_o(vdm_rdy),
      .cpl_valid_o(vdm_cpl), .cpl_ready_i(vdm_ack), .cpl_o(vdm_c), .vdm_o(vdm_rec)
    );
    g6lc_apu_vdp #(.Enable(1'b1)) i_vdp (
      .clk_i, .rst_ni, .cs_we_i(vdp_we), .cs_idx_i(vdp_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdp_rdata),
      .req_valid_i(vdp_req), .req_ready_o(vdp_rdy),
      .cpl_valid_o(vdp_cpl), .cpl_ready_i(vdp_ack), .cpl_o(vdp_c), .vdp_o(vdp_rec)
    );
    g6lc_apu_vdy #(.Enable(1'b1)) i_vdy (
      .clk_i, .rst_ni, .cs_we_i(vdy_we), .cs_idx_i(vdy_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdy_rdata),
      .req_valid_i(vdy_req), .req_ready_o(vdy_rdy),
      .cpl_valid_o(vdy_cpl), .cpl_ready_i(vdy_ack), .cpl_o(vdy_c), .vdy_o(vdy_rec)
    );
    g6lc_apu_vdt #(.Enable(1'b1)) i_vdt (
      .clk_i, .rst_ni, .cs_we_i(vdt_we), .cs_idx_i(vdt_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdt_rdata),
      .req_valid_i(vdt_req), .req_ready_o(vdt_rdy),
      .cpl_valid_o(vdt_cpl), .cpl_ready_i(vdt_ack), .cpl_o(vdt_c), .vdt_o(vdt_rec)
    );
    g6lc_apu_vdq #(.Enable(1'b1)) i_vdq (
      .clk_i, .rst_ni, .cs_we_i(vdq_we), .cs_idx_i(vdq_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdq_rdata),
      .req_valid_i(vdq_req), .req_ready_o(vdq_rdy),
      .cpl_valid_o(vdq_cpl), .cpl_ready_i(vdq_ack), .cpl_o(vdq_c), .vdq_o(vdq_rec)
    );
    g6lc_apu_vfs #(.Enable(1'b1)) i_vfs (
      .clk_i, .rst_ni, .cs_we_i(vfs_we), .cs_idx_i(vfs_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfs_rdata),
      .req_valid_i(vfs_req), .req_ready_o(vfs_rdy),
      .cpl_valid_o(vfs_cpl), .cpl_ready_i(vfs_ack), .cpl_o(vfs_c), .vfs_o(vfs_rec)
    );
    g6lc_apu_vrc #(.Enable(1'b1)) i_vrc (
      .clk_i, .rst_ni, .cs_we_i(vrc_we), .cs_idx_i(vrc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vrc_rdata),
      .req_valid_i(vrc_req), .req_ready_o(vrc_rdy),
      .cpl_valid_o(vrc_cpl), .cpl_ready_i(vrc_ack), .cpl_o(vrc_c), .vrc_o(vrc_rec)
    );
    g6lc_apu_vfc #(.Enable(1'b1)) i_vfc (
      .clk_i, .rst_ni, .cs_we_i(vfc_we), .cs_idx_i(vfc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfc_rdata),
      .req_valid_i(vfc_req), .req_ready_o(vfc_rdy),
      .cpl_valid_o(vfc_cpl), .cpl_ready_i(vfc_ack), .cpl_o(vfc_c), .vfc_o(vfc_rec)
    );
    g6lc_apu_vdd #(.Enable(1'b1)) i_vdd (
      .clk_i, .rst_ni, .cs_we_i(vdd_we), .cs_idx_i(vdd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdd_rdata),
      .req_valid_i(vdd_req), .req_ready_o(vdd_rdy),
      .cpl_valid_o(vdd_cpl), .cpl_ready_i(vdd_ack), .cpl_o(vdd_c), .vdd_o(vdd_rec)
    );
    g6lc_apu_vpc #(.Enable(1'b1)) i_vpc (
      .clk_i, .rst_ni, .cs_we_i(vpc_we), .cs_idx_i(vpc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vpc_rdata),
      .req_valid_i(vpc_req), .req_ready_o(vpc_rdy),
      .cpl_valid_o(vpc_cpl), .cpl_ready_i(vpc_ack), .cpl_o(vpc_c), .vpc_o(vpc_rec)
    );
    g6lc_apu_vdc #(.Enable(1'b1)) i_vdc (
      .clk_i, .rst_ni, .cs_we_i(vdc_we), .cs_idx_i(vdc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdc_rdata),
      .req_valid_i(vdc_req), .req_ready_o(vdc_rdy),
      .cpl_valid_o(vdc_cpl), .cpl_ready_i(vdc_ack), .cpl_o(vdc_c), .vdc_o(vdc_rec)
    );
    g6lc_apu_vdn #(.Enable(1'b1)) i_vdn (
      .clk_i, .rst_ni, .cs_we_i(vdn_we), .cs_idx_i(vdn_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vdn_rdata),
      .req_valid_i(vdn_req), .req_ready_o(vdn_rdy),
      .cpl_valid_o(vdn_cpl), .cpl_ready_i(vdn_ack), .cpl_o(vdn_c), .vdn_o(vdn_rec)
    );
    g6lc_apu_vgf #(.Enable(1'b1)) i_vgf (
      .clk_i, .rst_ni, .cs_we_i(vgf_we), .cs_idx_i(vgf_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vgf_rdata),
      .req_valid_i(vgf_req), .req_ready_o(vgf_rdy),
      .cpl_valid_o(vgf_cpl), .cpl_ready_i(vgf_ack), .cpl_o(vgf_c), .vgf_o(vgf_rec)
    );
    g6lc_apu_vip #(.Enable(1'b1)) i_vip (
      .clk_i, .rst_ni, .cs_we_i(vip_we), .cs_idx_i(vip_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vip_rdata),
      .req_valid_i(vip_req), .req_ready_o(vip_rdy),
      .cpl_valid_o(vip_cpl), .cpl_ready_i(vip_ack), .cpl_o(vip_c), .vip_o(vip_rec)
    );
    g6lc_apu_vxe #(.Enable(1'b1)) i_vxe (
      .clk_i, .rst_ni, .cs_we_i(vxe_we), .cs_idx_i(vxe_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vxe_rdata),
      .req_valid_i(vxe_req), .req_ready_o(vxe_rdy),
      .cpl_valid_o(vxe_cpl), .cpl_ready_i(vxe_ack), .cpl_o(vxe_c), .vxe_o(vxe_rec)
    );
    g6lc_apu_vrd #(.Enable(1'b1)) i_vrd (
      .clk_i, .rst_ni, .cs_we_i(vrd_we), .cs_idx_i(vrd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vrd_rdata),
      .req_valid_i(vrd_req), .req_ready_o(vrd_rdy),
      .cpl_valid_o(vrd_cpl), .cpl_ready_i(vrd_ack), .cpl_o(vrd_c), .vrd_o(vrd_rec)
    );
    g6lc_apu_vie #(.Enable(1'b1)) i_vie (
      .clk_i, .rst_ni, .cs_we_i(vie_we), .cs_idx_i(vie_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vie_rdata),
      .req_valid_i(vie_req), .req_ready_o(vie_rdy),
      .cpl_valid_o(vie_cpl), .cpl_ready_i(vie_ack), .cpl_o(vie_c), .vie_o(vie_rec)
    );
    g6lc_apu_vwl #(.Enable(1'b1)) i_vwl (
      .clk_i, .rst_ni, .cs_we_i(vwl_we), .cs_idx_i(vwl_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vwl_rdata),
      .req_valid_i(vwl_req), .req_ready_o(vwl_rdy),
      .cpl_valid_o(vwl_cpl), .cpl_ready_i(vwl_ack), .cpl_o(vwl_c), .vwl_o(vwl_rec)
    );
    g6lc_apu_vsl #(.Enable(1'b1)) i_vsl (
      .clk_i, .rst_ni, .cs_we_i(vsl_we), .cs_idx_i(vsl_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vsl_rdata),
      .req_valid_i(vsl_req), .req_ready_o(vsl_rdy),
      .cpl_valid_o(vsl_cpl), .cpl_ready_i(vsl_ack), .cpl_o(vsl_c), .vsl_o(vsl_rec)
    );
    g6lc_apu_vrg #(.Enable(1'b1)) i_vrg (
      .clk_i, .rst_ni, .cs_we_i(vrg_we), .cs_idx_i(vrg_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vrg_rdata),
      .req_valid_i(vrg_req), .req_ready_o(vrg_rdy),
      .cpl_valid_o(vrg_cpl), .cpl_ready_i(vrg_ack), .cpl_o(vrg_c), .vrg_o(vrg_rec)
    );
    g6lc_apu_vlw #(.Enable(1'b1)) i_vlw (
      .clk_i, .rst_ni, .cs_we_i(vlw_we), .cs_idx_i(vlw_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vlw_rdata),
      .req_valid_i(vlw_req), .req_ready_o(vlw_rdy),
      .cpl_valid_o(vlw_cpl), .cpl_ready_i(vlw_ack), .cpl_o(vlw_c), .vlw_o(vlw_rec)
    );
    g6lc_apu_vzb #(.Enable(1'b1)) i_vzb (
      .clk_i, .rst_ni, .cs_we_i(vzb_we), .cs_idx_i(vzb_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vzb_rdata),
      .req_valid_i(vzb_req), .req_ready_o(vzb_rdy),
      .cpl_valid_o(vzb_cpl), .cpl_ready_i(vzb_ack), .cpl_o(vzb_c), .vzb_o(vzb_rec)
    );
    g6lc_apu_vbc #(.Enable(1'b1)) i_vbc (
      .clk_i, .rst_ni, .cs_we_i(vbc_we), .cs_idx_i(vbc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbc_rdata),
      .req_valid_i(vbc_req), .req_ready_o(vbc_rdy),
      .cpl_valid_o(vbc_cpl), .cpl_ready_i(vbc_ack), .cpl_o(vbc_c), .vbc_o(vbc_rec)
    );
    g6lc_apu_vbo #(.Enable(1'b1)) i_vbo (
      .clk_i, .rst_ni, .cs_we_i(vbo_we), .cs_idx_i(vbo_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbo_rdata),
      .req_valid_i(vbo_req), .req_ready_o(vbo_rdy),
      .cpl_valid_o(vbo_cpl), .cpl_ready_i(vbo_ack), .cpl_o(vbo_c), .vbo_o(vbo_rec)
    );
    g6lc_apu_vcm #(.Enable(1'b1)) i_vcm (
      .clk_i, .rst_ni, .cs_we_i(vcm_we), .cs_idx_i(vcm_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vcm_rdata),
      .req_valid_i(vcm_req), .req_ready_o(vcm_rdy),
      .cpl_valid_o(vcm_cpl), .cpl_ready_i(vcm_ack), .cpl_o(vcm_c), .vcm_o(vcm_rec)
    );
    g6lc_apu_vwm #(.Enable(1'b1)) i_vwm (
      .clk_i, .rst_ni, .cs_we_i(vwm_we), .cs_idx_i(vwm_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vwm_rdata),
      .req_valid_i(vwm_req), .req_ready_o(vwm_rdy),
      .cpl_valid_o(vwm_cpl), .cpl_ready_i(vwm_ack), .cpl_o(vwm_c), .vwm_o(vwm_rec)
    );
    g6lc_apu_vrf #(.Enable(1'b1)) i_vrf (
      .clk_i, .rst_ni, .cs_we_i(vrf_we), .cs_idx_i(vrf_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vrf_rdata),
      .req_valid_i(vrf_req), .req_ready_o(vrf_rdy),
      .cpl_valid_o(vrf_cpl), .cpl_ready_i(vrf_ack), .cpl_o(vrf_c), .vrf_o(vrf_rec)
    );
    g6lc_apu_vcc #(.Enable(1'b1)) i_vcc (
      .clk_i, .rst_ni, .cs_we_i(vcc_we), .cs_idx_i(vcc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vcc_rdata),
      .req_valid_i(vcc_req), .req_ready_o(vcc_rdy),
      .cpl_valid_o(vcc_cpl), .cpl_ready_i(vcc_ack), .cpl_o(vcc_c), .vcc_o(vcc_rec)
    );
    g6lc_apu_vcy #(.Enable(1'b1)) i_vcy (
      .clk_i, .rst_ni, .cs_we_i(vcy_we), .cs_idx_i(vcy_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vcy_rdata),
      .req_valid_i(vcy_req), .req_ready_o(vcy_rdy),
      .cpl_valid_o(vcy_cpl), .cpl_ready_i(vcy_ack), .cpl_o(vcy_c), .vcy_o(vcy_rec)
    );
    g6lc_apu_vbl #(.Enable(1'b1)) i_vbl (
      .clk_i, .rst_ni, .cs_we_i(vbl_we), .cs_idx_i(vbl_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbl_rdata),
      .req_valid_i(vbl_req), .req_ready_o(vbl_rdy),
      .cpl_valid_o(vbl_cpl), .cpl_ready_i(vbl_ack), .cpl_o(vbl_c), .vbl_o(vbl_rec)
    );
    g6lc_apu_vbt #(.Enable(1'b1)) i_vbt (
      .clk_i, .rst_ni, .cs_we_i(vbt_we), .cs_idx_i(vbt_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vbt_rdata),
      .req_valid_i(vbt_req), .req_ready_o(vbt_rdy),
      .cpl_valid_o(vbt_cpl), .cpl_ready_i(vbt_ack), .cpl_o(vbt_c), .vbt_o(vbt_rec)
    );
    g6lc_apu_vic #(.Enable(1'b1)) i_vic (
      .clk_i, .rst_ni, .cs_we_i(vic_we), .cs_idx_i(vic_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vic_rdata),
      .req_valid_i(vic_req), .req_ready_o(vic_rdy),
      .cpl_valid_o(vic_cpl), .cpl_ready_i(vic_ack), .cpl_o(vic_c), .vic_o(vic_rec)
    );
    g6lc_apu_vub #(.Enable(1'b1)) i_vub (
      .clk_i, .rst_ni, .cs_we_i(vub_we), .cs_idx_i(vub_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vub_rdata),
      .req_valid_i(vub_req), .req_ready_o(vub_rdy),
      .cpl_valid_o(vub_cpl), .cpl_ready_i(vub_ack), .cpl_o(vub_c), .vub_o(vub_rec)
    );
    g6lc_apu_vfl #(.Enable(1'b1)) i_vfl (
      .clk_i, .rst_ni, .cs_we_i(vfl_we), .cs_idx_i(vfl_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfl_rdata),
      .req_valid_i(vfl_req), .req_ready_o(vfl_rdy),
      .cpl_valid_o(vfl_cpl), .cpl_ready_i(vfl_ack), .cpl_o(vfl_c), .vfl_o(vfl_rec)
    );
    g6lc_apu_vcl #(.Enable(1'b1)) i_vcl (
      .clk_i, .rst_ni, .cs_we_i(vcl_we), .cs_idx_i(vcl_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vcl_rdata),
      .req_valid_i(vcl_req), .req_ready_o(vcl_rdy),
      .cpl_valid_o(vcl_cpl), .cpl_ready_i(vcl_ack), .cpl_o(vcl_c), .vcl_o(vcl_rec)
    );
    g6lc_apu_vio #(.Enable(1'b1)) i_vio (
      .clk_i, .rst_ni, .cs_we_i(vio_we), .cs_idx_i(vio_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vio_rdata),
      .req_valid_i(vio_req), .req_ready_o(vio_rdy),
      .cpl_valid_o(vio_cpl), .cpl_ready_i(vio_ack), .cpl_o(vio_c), .vio_o(vio_rec)
    );
    g6lc_apu_vix #(.Enable(1'b1)) i_vix (
      .clk_i, .rst_ni, .cs_we_i(vix_we), .cs_idx_i(vix_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vix_rdata),
      .req_valid_i(vix_req), .req_ready_o(vix_rdy),
      .cpl_valid_o(vix_cpl), .cpl_ready_i(vix_ack), .cpl_o(vix_c), .vix_o(vix_rec)
    );
    g6lc_apu_vds #(.Enable(1'b1)) i_vds (
      .clk_i, .rst_ni, .cs_we_i(vds_we), .cs_idx_i(vds_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vds_rdata),
      .req_valid_i(vds_req), .req_ready_o(vds_rdy),
      .cpl_valid_o(vds_cpl), .cpl_ready_i(vds_ack), .cpl_o(vds_c), .vds_o(vds_rec)
    );
    g6lc_apu_vat #(.Enable(1'b1)) i_vat (
      .clk_i, .rst_ni, .cs_we_i(vat_we), .cs_idx_i(vat_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vat_rdata),
      .req_valid_i(vat_req), .req_ready_o(vat_rdy),
      .cpl_valid_o(vat_cpl), .cpl_ready_i(vat_ack), .cpl_o(vat_c), .vat_o(vat_rec)
    );
    g6lc_apu_vin #(.Enable(1'b1)) i_vin (
      .clk_i, .rst_ni, .cs_we_i(vin_we), .cs_idx_i(vin_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vin_rdata),
      .req_valid_i(vin_req), .req_ready_o(vin_rdy),
      .cpl_valid_o(vin_cpl), .cpl_ready_i(vin_ack), .cpl_o(vin_c), .vin_o(vin_rec)
    );
    g6lc_apu_vrs #(.Enable(1'b1)) i_vrs (
      .clk_i, .rst_ni, .cs_we_i(vrs_we), .cs_idx_i(vrs_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vrs_rdata),
      .req_valid_i(vrs_req), .req_ready_o(vrs_rdy),
      .cpl_valid_o(vrs_cpl), .cpl_ready_i(vrs_ack), .cpl_o(vrs_c), .vrs_o(vrs_rec)
    );
    g6lc_apu_vgs #(.Enable(1'b1)) i_vgs (
      .clk_i, .rst_ni, .cs_we_i(vgs_we), .cs_idx_i(vgs_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vgs_rdata),
      .req_valid_i(vgs_req), .req_ready_o(vgs_rdy),
      .cpl_valid_o(vgs_cpl), .cpl_ready_i(vgs_ack), .cpl_o(vgs_c), .vgs_o(vgs_rec)
    );
    g6lc_apu_vwf #(.Enable(1'b1)) i_vwf (
      .clk_i, .rst_ni, .cs_we_i(vwf_we), .cs_idx_i(vwf_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vwf_rdata),
      .req_valid_i(vwf_req), .req_ready_o(vwf_rdy),
      .cpl_valid_o(vwf_cpl), .cpl_ready_i(vwf_ack), .cpl_o(vwf_c), .vwf_o(vwf_rec)
    );
    g6lc_apu_vfr #(.Enable(1'b1)) i_vfr (
      .clk_i, .rst_ni, .cs_we_i(vfr_we), .cs_idx_i(vfr_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfr_rdata),
      .req_valid_i(vfr_req), .req_ready_o(vfr_rdy),
      .cpl_valid_o(vfr_cpl), .cpl_ready_i(vfr_ack), .cpl_o(vfr_c), .vfr_o(vfr_rec)
    );
    g6lc_apu_vfn #(.Enable(1'b1)) i_vfn (
      .clk_i, .rst_ni, .cs_we_i(vfn_we), .cs_idx_i(vfn_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vfn_rdata),
      .req_valid_i(vfn_req), .req_ready_o(vfn_rdy),
      .cpl_valid_o(vfn_cpl), .cpl_ready_i(vfn_ack), .cpl_o(vfn_c), .vfn_o(vfn_rec)
    );












    g6lc_apu_gnh #(.Enable(1'b1)) i_gnh (
      .clk_i, .rst_ni,
      .req_valid_i(gnh_req_v), .req_ready_o(gnh_rdy), .req_i(gnh_req_q),
      .cpl_valid_o(gnh_cpl), .cpl_ready_i(gnh_ack), .cpl_o(gnh_c), .gnh_o(gnh_rec)
    );
    g6lc_apu_spirv #(.Enable(1'b1)) i_spv (
      .clk_i, .rst_ni, .prog_we_i(spv_we), .prog_idx_i(spv_idx),
      .prog_wdata_i(spv_wdata), .prog_len_i(spv_len), .commit_i(spv_commit),
      .start_i(spv_start), .in_a_i(in_a_q), .in_b_i(in_b_q),
      .idle_o(spv_idle), .busy_o(spv_busy), .done_o(spv_done),
      .fault_o(spv_fault), .irq_o(spv_irq), .result_o(spv_res)
    );

    logic unused_vnd;
    assign unused_vnd = |vnd_rdata | |vwi_rdata | |vgq_rdata | |vcd_rdata |
                        |vci_rdata | |vep_rdata | |vqf_rdata | |vpf_rdata |
                        |vpp_rdata | |vmp_rdata | |vam_rdata | |vxb_rdata |
                        |vbb_rdata | |vmm_rdata | |vum_rdata | |vbm_rdata |
                        |vfm_rdata | |vim_rdata | |vmc_rdata |
                        |vdl_rdata | |vpl_rdata | |vcp_rdata |
                        |vda_rdata | |vud_rdata | |vbp_rdata | |vbd_rdata |
                        |vpo_rdata | |vxi_rdata | |vbi_rdata | |vmi_rdata |
                        |vxv_rdata | |vsm_rdata | |vrp_rdata | |vgp_rdata |
                        |vfb_rdata | |vrb_rdata | |vdw_rdata | |vre_rdata |
                        |vvb_rdata | |vib_rdata | |vdi_rdata |
                        |vvp_rdata | |vsi_rdata | |vpb_rdata | |vns_rdata |
                        |vdf_rdata | |vdx_rdata | |vdk_rdata | |vdr_rdata |
                        |vdb_rdata | |vdg_rdata | |vfe_rdata | |vdm_rdata |
                        |vdp_rdata | |vdy_rdata | |vdt_rdata | |vdq_rdata |
                        |vfs_rdata | |vrc_rdata | |vfc_rdata | |vdd_rdata |
                        |vpc_rdata | |vdc_rdata | |vdn_rdata |
                        |vgf_rdata | |vip_rdata | |vxe_rdata | |vrd_rdata |
                        |vie_rdata | |vwl_rdata | |vsl_rdata | |vrg_rdata |
                        |vlw_rdata | |vzb_rdata | |vbc_rdata | |vbo_rdata |
                        |vcm_rdata | |vwm_rdata | |vrf_rdata |
                        |vcc_rdata | |vcy_rdata | |vbl_rdata | |vbt_rdata |
                        |vic_rdata | |vub_rdata | |vfl_rdata | |vcl_rdata |
                        |vio_rdata | |vix_rdata | |vds_rdata | |vat_rdata |
                        |vin_rdata | |vrs_rdata |
                        |vgs_rdata | |vwf_rdata | |vfr_rdata | |vfn_rdata |
                        spv_idle | spv_busy | spv_done;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cs_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
        alloc_q <= 1'b0;
        begin_q <= 1'b0;
        end_q <= 1'b0;
        create_q <= 1'b0;
        disp_q <= 1'b0;
        submit_q <= 1'b0;
        wait_q <= 1'b0;
        queue_q <= 1'b0;
        device_q <= 1'b0;
        instance_q <= 1'b0;
        enum_q <= 1'b0;
        qfam_q <= 1'b0;
        feat_q <= 1'b0;
        props_q <= 1'b0;
        mem_q <= 1'b0;
        vkmem_q <= 1'b0;
        buffer_q <= 1'b0;
        bind_q <= 1'b0;
        bind_mem_q <= 1'b0;
        map_q <= 1'b0;
        unmap_q <= 1'b0;
        bufreq_q <= 1'b0;
        flush_q <= 1'b0;
        inval_q <= 1'b0;
        memc_q <= 1'b0;
        dsl_q <= 1'b0;
        pl_q <= 1'b0;
        cpipe_q <= 1'b0;
        dsl_ok_q <= 1'b0;
        pl_ok_q <= 1'b0;
        dset_q <= 1'b0; upd_q <= 1'b0; upd_buf_q <= 1'b0;
        bp_q <= 1'b0; bd_q <= 1'b0;
        dset_ok_q <= 1'b0; pipe_bound_q <= 1'b0; desc_bound_q <= 1'b0;
        pool_q <= 1'b0; img_q <= 1'b0; bindimg_q <= 1'b0; bindimg_mem_q <= 1'b0;
        imgreq_q <= 1'b0; dset_pool_q <= 1'b0; pool_ok_q <= 1'b0; pool_h_q <= '0;
        view_q <= 1'b0; samp_q <= 1'b0; rpass_q <= 1'b0; gpipe_q <= 1'b0; rp_ok_q <= 1'b0;
        fbuf_q <= 1'b0; beginrp_q <= 1'b0; draw_q <= 1'b0; endrp_q <= 1'b0;
        fbuf_ok_q <= 1'b0; in_rp_q <= 1'b0;
        vtx_q <= 1'b0; idxb_q <= 1'b0; drawi_q <= 1'b0;
        vtx_buf_q <= 1'b0; idx_buf_q <= 1'b0; vtx_bound_q <= 1'b0; idx_bound_q <= 1'b0;
        vp_q <= 1'b0; sc_q <= 1'b0; bar_q <= 1'b0; nextsp_q <= 1'b0;
        dfb_q <= 1'b0; dvw_q <= 1'b0; dsm_q <= 1'b0; drp_q <= 1'b0;
        dfb_ret_q <= 1'b0; dvw_ret_q <= 1'b0; dsm_ret_q <= 1'b0; drp_ret_q <= 1'b0;
        dbf_q <= 1'b0; dim_q <= 1'b0; fme_q <= 1'b0; dmd_q <= 1'b0;
        dbf_ret_q <= 1'b0; dim_ret_q <= 1'b0; fme_ret_q <= 1'b0; dmd_ret_q <= 1'b0;
        dpl_q <= 1'b0; dyo_q <= 1'b0; dds_q <= 1'b0; dpo_q <= 1'b0;
        dpl_ret_q <= 1'b0; dyo_ret_q <= 1'b0; dds_ret_q <= 1'b0; dpo_ret_q <= 1'b0;
        fds_q <= 1'b0; rcb_q <= 1'b0; fcb_q <= 1'b0; ddv_q <= 1'b0;
        fds_ret_q <= 1'b0; fcb_ret_q <= 1'b0; ddv_ret_q <= 1'b0;
        rcp_q <= 1'b0; dcp_q <= 1'b0; din_q <= 1'b0; din_ret_q <= 1'b0;
        fmt_q <= 1'b0; ifmt_q <= 1'b0; dext_q <= 1'b0; rdp_q <= 1'b0;
        iex_q <= 1'b0; dwi_q <= 1'b0; isl_q <= 1'b0; rag_q <= 1'b0;
        slw_q <= 1'b0; sdb_q <= 1'b0; sbc_q <= 1'b0; sbb_q <= 1'b0;
        scm_q <= 1'b0; swm_q <= 1'b0; srf_q <= 1'b0;
        ccb_q <= 1'b0; cci_q <= 1'b0; bli_q <= 1'b0; cbi_q <= 1'b0;
        copy_src_q <= 1'b0; copy_dst_q <= 1'b0;
        cib_q <= 1'b0; ubu_q <= 1'b0; fil_q <= 1'b0; ccl_q <= 1'b0;
        dinr_q <= 1'b0; didi_q <= 1'b0; cds_q <= 1'b0; cat_q <= 1'b0;
        dsi_q <= 1'b0; rsl_q <= 1'b0;
        gfs_q <= 1'b0; wfe_q <= 1'b0; rfe_q <= 1'b0; dfe_q <= 1'b0;
        look_q <= 1'b0;
        loaded_q <= 1'b0;
        begun_q <= 1'b0;
        ended_q <= 1'b0;
        submitted_q <= 1'b0;
        queued_q <= 1'b0;
        instanced_q <= 1'b0;
        qfam_ok_q <= 1'b0;
        feat_ok_q <= 1'b0;
        props_ok_q <= 1'b0;
        mem_ok_q <= 1'b0;
        bind_ok_q <= 1'b0;
        map_ok_q <= 1'b0;
        load_q <= '0;
        n_q <= '0;
        in_a_q <= '0;
        in_b_q <= '0;
        result_q <= '0;
        begun_handle_q <= '0;
        ended_handle_q <= '0;
        queue_handle_q <= '0;
        qreply0_q <= '0;
        qreply1_q <= '0;
        dreply_q <= '{default: '0};
        ireply_q <= '{default: '0};
        preply_q <= '{default: '0};
        freply_q <= '{default: '0};
        ereply_q <= '{default: '0};
        sreply_q <= '{default: '0};
        mreply_q <= '{default: '0};
        areply_q <= '{default: '0};
        breply_q <= '{default: '0};
        nreply_q <= '{default: '0};
        ureply_q <= '{default: '0};
        wreply_q <= '{default: '0};
        xreply_q <= '{default: '0};
        yreply_q <= '{default: '0};
        zreply_q <= '{default: '0};
        creply_q <= '{default: '0};
        lreply_q <= '{default: '0};
        kreply_q <= '{default: '0};
        oreply_q <= '{default: '0};
        jreply_q <= '{default: '0};
        treply_q <= '{default: '0};
        hreply_q <= '{default: '0};
        greply_q <= '{default: '0};
        rreply_q <= '{default: '0};
        ximg_q <= '{default: '0};
        bimg_q <= '{default: '0};
        mimg_q <= '{default: '0};
        tail_q <= '{default: '0};
        begin_flags_q <= '0;
        gnh_req_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i && (cs_idx_i < 8'(APU_VAC_WORDS)))
            cs_q[cs_idx_i[4:0]] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            alloc_q <= req_i.op == APU_BRU_ALLOC;
            begin_q <= req_i.op == APU_BRU_BEGIN;
            end_q <= req_i.op == APU_BRU_END;
            create_q <= req_i.op == APU_BRU_CREATE;
            disp_q <= req_i.op == APU_BRU_DISPATCH;
            submit_q <= req_i.op == APU_BRU_SUBMIT;
            wait_q <= req_i.op == APU_BRU_WAIT;
            queue_q <= req_i.op == APU_BRU_QUEUE;
            device_q <= req_i.op == APU_BRU_DEVICE;
            instance_q <= req_i.op == APU_BRU_INSTANCE;
            enum_q <= req_i.op == APU_BRU_ENUM;
            qfam_q <= req_i.op == APU_BRU_QFAM;
            feat_q <= req_i.op == APU_BRU_FEAT;
            props_q <= req_i.op == APU_BRU_PROPS;
            mem_q <= req_i.op == APU_BRU_MEM;
            vkmem_q <= req_i.op == APU_BRU_VKMEM;
            buffer_q <= req_i.op == APU_BRU_BUFFER;
            bind_q <= req_i.op == APU_BRU_BIND;
            bind_mem_q <= 1'b0;
            map_q <= req_i.op == APU_BRU_MAP;
            unmap_q <= req_i.op == APU_BRU_UNMAP;
            bufreq_q <= req_i.op == APU_BRU_BUFREQ;
            flush_q <= req_i.op == APU_BRU_FLUSH;
            inval_q <= req_i.op == APU_BRU_INVAL;
            memc_q <= req_i.op == APU_BRU_MEMC;
            dsl_q <= req_i.op == APU_BRU_DSLAYOUT;
            pl_q <= req_i.op == APU_BRU_PLAYOUT;
            cpipe_q <= req_i.op == APU_BRU_CPIPE;
            dset_q <= req_i.op == APU_BRU_DESCSET;
            upd_q <= req_i.op == APU_BRU_UPDATE;
            upd_buf_q <= 1'b0;
            bp_q <= req_i.op == APU_BRU_BINDPIPE;
            bd_q <= req_i.op == APU_BRU_BINDDESC;
            pool_q <= req_i.op == APU_BRU_POOL;
            img_q <= req_i.op == APU_BRU_IMAGE;
            bindimg_q <= req_i.op == APU_BRU_BINDIMG;
            bindimg_mem_q <= 1'b0;
            imgreq_q <= req_i.op == APU_BRU_IMGREQ;
            dset_pool_q <= 1'b0;
            view_q <= req_i.op == APU_BRU_VIEW;
            samp_q <= req_i.op == APU_BRU_SAMPLER;
            rpass_q <= req_i.op == APU_BRU_RPASS;
            gpipe_q <= req_i.op == APU_BRU_GPIPE;
            fbuf_q <= req_i.op == APU_BRU_FBUF;
            beginrp_q <= req_i.op == APU_BRU_BEGINRP;
            draw_q <= req_i.op == APU_BRU_DRAW;
            endrp_q <= req_i.op == APU_BRU_ENDRP;
            vtx_q <= req_i.op == APU_BRU_BINDVTX;
            idxb_q <= req_i.op == APU_BRU_BINDIDX;
            drawi_q <= req_i.op == APU_BRU_DRAWIDX;
            vp_q <= req_i.op == APU_BRU_SETVP;
            sc_q <= req_i.op == APU_BRU_SETSC;
            bar_q <= req_i.op == APU_BRU_BARRIER;
            nextsp_q <= req_i.op == APU_BRU_NEXTSP;
            dfb_q <= req_i.op == APU_BRU_DFB;
            dvw_q <= req_i.op == APU_BRU_DVW;
            dsm_q <= req_i.op == APU_BRU_DSM;
            drp_q <= req_i.op == APU_BRU_DRP;
            dbf_q <= req_i.op == APU_BRU_DBF;
            dim_q <= req_i.op == APU_BRU_DIM;
            fme_q <= req_i.op == APU_BRU_FME;
            dmd_q <= req_i.op == APU_BRU_DMD;
            dpl_q <= req_i.op == APU_BRU_DPL;
            dyo_q <= req_i.op == APU_BRU_DYO;
            dds_q <= req_i.op == APU_BRU_DDS;
            dpo_q <= req_i.op == APU_BRU_DPO;
            fds_q <= req_i.op == APU_BRU_FDS;
            rcb_q <= req_i.op == APU_BRU_RCB;
            fcb_q <= req_i.op == APU_BRU_FCB;
            ddv_q <= req_i.op == APU_BRU_DDV;
            rcp_q <= req_i.op == APU_BRU_RCP;
            dcp_q <= req_i.op == APU_BRU_DCP;
            din_q <= req_i.op == APU_BRU_DIN;
            fmt_q <= req_i.op == APU_BRU_GFP;
            ifmt_q <= req_i.op == APU_BRU_IFP;
            dext_q <= req_i.op == APU_BRU_DEX;
            rdp_q <= req_i.op == APU_BRU_RDP;
            iex_q <= req_i.op == APU_BRU_IEX;
            dwi_q <= req_i.op == APU_BRU_DWI;
            isl_q <= req_i.op == APU_BRU_ISL;
            rag_q <= req_i.op == APU_BRU_RAG;
            slw_q <= req_i.op == APU_BRU_SLW;
            sdb_q <= req_i.op == APU_BRU_SDB;
            sbc_q <= req_i.op == APU_BRU_SBC;
            sbb_q <= req_i.op == APU_BRU_SBB;
            scm_q <= req_i.op == APU_BRU_SCM;
            swm_q <= req_i.op == APU_BRU_SWM;
            srf_q <= req_i.op == APU_BRU_SRF;
            ccb_q <= req_i.op == APU_BRU_CCB;
            cci_q <= req_i.op == APU_BRU_CCI;
            bli_q <= req_i.op == APU_BRU_BLI;
            cbi_q <= req_i.op == APU_BRU_CBI;
            cib_q <= req_i.op == APU_BRU_CIB;
            ubu_q <= req_i.op == APU_BRU_UBF;
            fil_q <= req_i.op == APU_BRU_FIL;
            ccl_q <= req_i.op == APU_BRU_CCL;
            dinr_q <= req_i.op == APU_BRU_DRI;
            didi_q <= req_i.op == APU_BRU_DXI;
            cds_q <= req_i.op == APU_BRU_CDS;
            cat_q <= req_i.op == APU_BRU_CAT;
            dsi_q <= req_i.op == APU_BRU_DSI;
            rsl_q <= req_i.op == APU_BRU_RSI;
            gfs_q <= req_i.op == APU_BRU_GFS;
            wfe_q <= req_i.op == APU_BRU_WFE;
            rfe_q <= req_i.op == APU_BRU_RFE;
            dfe_q <= req_i.op == APU_BRU_DFE;
            dfb_ret_q <= 1'b0; dvw_ret_q <= 1'b0; dsm_ret_q <= 1'b0; drp_ret_q <= 1'b0;
            dbf_ret_q <= 1'b0; dim_ret_q <= 1'b0; fme_ret_q <= 1'b0; dmd_ret_q <= 1'b0;
            dpl_ret_q <= 1'b0; dyo_ret_q <= 1'b0; dds_ret_q <= 1'b0; dpo_ret_q <= 1'b0;
            fds_ret_q <= 1'b0; fcb_ret_q <= 1'b0; ddv_ret_q <= 1'b0;
            din_ret_q <= 1'b0;
            vtx_buf_q <= 1'b0; idx_buf_q <= 1'b0;
            copy_src_q <= 1'b0; copy_dst_q <= 1'b0;
            look_q <= 1'b0;
            in_a_q <= in_a_i;
            in_b_q <= in_b_i;
            unique case (req_i.op)
              APU_BRU_GNH: begin
                gnh_req_q <= req_i.gnh;
                state_q <= FireGnh;
              end
              APU_BRU_CREATE: state_q <= FireEnc;
              APU_BRU_BEGIN: state_q <= FireVbg;
              APU_BRU_END: state_q <= FireVen;
              APU_BRU_SUBMIT: state_q <= FireVqs;
              APU_BRU_WAIT: state_q <= FireVwi;
              APU_BRU_QUEUE: state_q <= FireVgq;
              APU_BRU_DEVICE: state_q <= FireVcd;
              APU_BRU_INSTANCE: state_q <= FireVci;
              APU_BRU_ENUM: state_q <= FireVep;
              APU_BRU_QFAM: state_q <= FireVqf;
              APU_BRU_FEAT: state_q <= FireVpf;
              APU_BRU_PROPS: state_q <= FireVpp;
              APU_BRU_MEM: state_q <= FireVmp;
              APU_BRU_VKMEM: state_q <= FireVam;
              APU_BRU_BUFFER: state_q <= FireVxb;
              APU_BRU_BIND: state_q <= FireVbb;
              APU_BRU_MAP: state_q <= FireVmm;
              APU_BRU_UNMAP: state_q <= FireVum;
              APU_BRU_BUFREQ: state_q <= FireVbm;
              APU_BRU_FLUSH: state_q <= FireVfm;
              APU_BRU_INVAL: state_q <= FireVim;
              APU_BRU_MEMC: state_q <= FireVmc;
              APU_BRU_DSLAYOUT: state_q <= FireVdl;
              APU_BRU_PLAYOUT: state_q <= FireVpl;
              APU_BRU_CPIPE: state_q <= FireVcp;
              APU_BRU_DESCSET: state_q <= FireVda;
              APU_BRU_UPDATE: state_q <= FireVud;
              APU_BRU_BINDPIPE: state_q <= FireVbp;
              APU_BRU_BINDDESC: state_q <= FireVbd;
              APU_BRU_POOL: state_q <= FireVpo;
              APU_BRU_IMAGE: state_q <= FireVxi;
              APU_BRU_BINDIMG: state_q <= FireVbi;
              APU_BRU_IMGREQ: state_q <= FireVmi;
              APU_BRU_VIEW: state_q <= FireVxv;
              APU_BRU_SAMPLER: state_q <= FireVsm;
              APU_BRU_RPASS: state_q <= FireVrp;
              APU_BRU_GPIPE: state_q <= FireVgp;
              APU_BRU_FBUF: state_q <= FireVfb;
              APU_BRU_BEGINRP: state_q <= FireVrb;
              APU_BRU_DRAW: state_q <= FireVdw;
              APU_BRU_ENDRP: state_q <= FireVre;
              APU_BRU_BINDVTX: state_q <= FireVvb;
              APU_BRU_BINDIDX: state_q <= FireVib;
              APU_BRU_DRAWIDX: state_q <= FireVdi;
              APU_BRU_SETVP: state_q <= FireVvp;
              APU_BRU_SETSC: state_q <= FireVsi;
              APU_BRU_BARRIER: state_q <= FireVpb;
              APU_BRU_NEXTSP: state_q <= FireVns;
              APU_BRU_DFB: state_q <= FireVdf;
              APU_BRU_DVW: state_q <= FireVdx;
              APU_BRU_DSM: state_q <= FireVdk;
              APU_BRU_DRP: state_q <= FireVdr;
              APU_BRU_DBF: state_q <= FireVdb;
              APU_BRU_DIM: state_q <= FireVdg;
              APU_BRU_FME: state_q <= FireVfe;
              APU_BRU_DMD: state_q <= FireVdm;
              APU_BRU_DPL: state_q <= FireVdp;
              APU_BRU_DYO: state_q <= FireVdy;
              APU_BRU_DDS: state_q <= FireVdt;
              APU_BRU_DPO: state_q <= FireVdq;
              APU_BRU_FDS: state_q <= FireVfs;
              APU_BRU_RCB: state_q <= FireVrc;
              APU_BRU_FCB: state_q <= FireVfc;
              APU_BRU_DDV: state_q <= FireVdd;
              APU_BRU_RCP: state_q <= FireVpc;
              APU_BRU_DCP: state_q <= FireVdc;
              APU_BRU_DIN: state_q <= FireVdn;
              APU_BRU_GFP: state_q <= FireVgf;
              APU_BRU_IFP: state_q <= FireVip;
              APU_BRU_DEX: state_q <= FireVxe;
              APU_BRU_RDP: state_q <= FireVrd;
              APU_BRU_IEX: state_q <= FireVie;
              APU_BRU_DWI: state_q <= FireVwl;
              APU_BRU_ISL: state_q <= FireVsl;
              APU_BRU_RAG: state_q <= FireVrg;
              APU_BRU_SLW: state_q <= FireVlw;
              APU_BRU_SDB: state_q <= FireVzb;
              APU_BRU_SBC: state_q <= FireVbc;
              APU_BRU_SBB: state_q <= FireVbo;
              APU_BRU_SCM: state_q <= FireVcm;
              APU_BRU_SWM: state_q <= FireVwm;
              APU_BRU_SRF: state_q <= FireVrf;
              APU_BRU_CCB: state_q <= FireVcc;
              APU_BRU_CCI: state_q <= FireVcy;
              APU_BRU_BLI: state_q <= FireVbl;
              APU_BRU_CBI: state_q <= FireVbt;
              APU_BRU_CIB: state_q <= FireVic;
              APU_BRU_UBF: state_q <= FireVub;
              APU_BRU_FIL: state_q <= FireVfl;
              APU_BRU_CCL: state_q <= FireVcl;
              APU_BRU_DRI: state_q <= FireVio;
              APU_BRU_DXI: state_q <= FireVix;
              APU_BRU_CDS: state_q <= FireVds;
              APU_BRU_CAT: state_q <= FireVat;
              APU_BRU_DSI: state_q <= FireVin;
              APU_BRU_RSI: state_q <= FireVrs;
              APU_BRU_GFS: state_q <= FireVgs;
              APU_BRU_WFE: state_q <= FireVwf;
              APU_BRU_RFE: state_q <= FireVfr;
              APU_BRU_DFE: state_q <= FireVfn;
              APU_BRU_DISPATCH: begin
                if (!loaded_q || !begun_q || !pipe_bound_q || !desc_bound_q) begin
                  cpl_q <= '{status: APU_BRU_FAULT};
                  state_q <= Done;
                end else state_q <= FireVnd;
              end
              APU_BRU_ALLOC: begin
                if (!decode_ok) begin
                  cpl_q <= '{status: APU_BRU_FAULT};
                  state_q <= Done;
                end else begin
                  rec_q <= '{
                    valid:       1'b0,
                    alloc:       1'b1,
                    begin_cmd:   1'b0,
                    end_cmd:     1'b0,
                    create:      1'b0,
                    dispatch:    1'b0,
                    submit:      1'b0,
                    wait_idle:  1'b0,
                    get_queue:   1'b0,
                    create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
                    loaded:      loaded_q,
                    begun:       begun_q,
                    reply:       want_reply,
                    slot:        '0,
                    gen:         '0,
                    kind:        APU_GNH_CMDBUF,
                    object_id:   guest[31:0],
                    handle:      '0,
                    begin_flags: begin_flags_q,
                    code_words:  '0,
                    group_x:     '0,
                    group_y:     '0,
                    group_z:     '0,
                    result:      '0
                  };
                  gnh_req_q <= '{
                    op: APU_GNH_ALLOC,
                    kind: APU_GNH_CMDBUF,
                    object_id: guest[31:0],
                    handle: '0
                  };
                  state_q <= FireGnh;
                end
              end
              default: begin
                cpl_q <= '{status: APU_BRU_FAULT};
                state_q <= Done;
              end
            endcase
          end
        end
        FireVbg: if (vbg_rdy) state_q <= WaitVbg;
        WaitVbg: if (vbg_cpl) begin
          if (vbg_c.status != APU_VBG_OK || !vbg_rec.valid ||
              vbg_rec.command_buffer[63:32] != 32'd0) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b1,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:  1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       1'b0,
              reply:       vbg_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_CMDBUF,
              object_id:   '0,
              handle:      vbg_rec.command_buffer[31:0],
              begin_flags: vbg_rec.begin_flags,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: vbg_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVen: if (ven_rdy) state_q <= WaitVen;
        WaitVen: if (ven_cpl) begin
          if (ven_c.status != APU_VEN_OK || !ven_rec.valid ||
              ven_rec.command_buffer[63:32] != 32'd0) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b1,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:  1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       1'b0,
              reply:       ven_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_CMDBUF,
              object_id:   '0,
              handle:      ven_rec.command_buffer[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: ven_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVqs: if (vqs_rdy) state_q <= WaitVqs;
        WaitVqs: if (vqs_cpl) begin
          if (vqs_c.status != APU_VQS_OK || !vqs_rec.valid ||
              vqs_rec.command_buffer[63:32] != 32'd0) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b1,
              wait_idle:  1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       1'b0,
              reply:       vqs_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_CMDBUF,
              object_id:   '0,
              handle:      vqs_rec.command_buffer[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      result_q
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: vqs_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVwi: if (vwi_rdy) state_q <= WaitVwi;
        WaitVwi: if (vwi_cpl) begin
          if (vwi_c.status != APU_VWI_OK || !vwi_rec.valid || !submitted_q ||
              !queued_q || vwi_rec.queue_handle[31:0] != queue_handle_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b1,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b1,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       1'b0,
              reply:       vwi_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_CMDBUF,
              object_id:   '0,
              handle:      ended_handle_q,
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      32'd0
            };
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end
        end
        FireVgq: if (vgq_rdy) state_q <= WaitVgq;
        WaitVgq: if (vgq_cpl) begin
          if (vgq_c.status != APU_VGQ_OK || !vgq_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b1,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vgq_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_DEVICE,
              object_id:   '0,
              handle:      vgq_rec.device[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_DEVICE,
              object_id: '0,
              handle: vgq_rec.device[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVam: if (vam_rdy) state_q <= WaitVam;
        WaitVam: if (vam_cpl) begin
          if (vam_c.status != APU_VAM_OK || !vam_rec.valid || !mem_ok_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b1,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vam_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_DEVICE,
              object_id:   vam_rec.guest[31:0],
              handle:      vam_rec.device[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_DEVICE,
              object_id: '0,
              handle: vam_rec.device[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVxb: if (vxb_rdy) state_q <= WaitVxb;
        WaitVxb: if (vxb_cpl) begin
          if (vxb_c.status != APU_VXB_OK || !vxb_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b1,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vxb_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_DEVICE,
              object_id:   vxb_rec.guest[31:0],
              handle:      vxb_rec.device[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_DEVICE,
              object_id: '0,
              handle: vxb_rec.device[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVbb: if (vbb_rdy) state_q <= WaitVbb;
        WaitVbb: if (vbb_cpl) begin
          if (vbb_c.status != APU_VBB_OK || !vbb_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b1,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vbb_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_BUFFER,
              object_id:   vbb_rec.memory[31:0],
              handle:      vbb_rec.buffer[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_BUFFER,
              object_id: '0,
              handle: vbb_rec.buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVmm: if (vmm_rdy) state_q <= WaitVmm;
        WaitVmm: if (vmm_cpl) begin
          if (vmm_c.status != APU_VMM_OK || !vmm_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b1,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vmm_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_MEMORY,
              object_id:   vmm_rec.guest[31:0],
              handle:      vmm_rec.memory[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_MEMORY,
              object_id: '0,
              handle: vmm_rec.memory[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVum: if (vum_rdy) state_q <= WaitVum;
        WaitVum: if (vum_cpl) begin
          if (vum_c.status != APU_VUM_OK || !vum_rec.valid || !map_ok_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b1,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vum_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_MEMORY,
              object_id:   '0,
              handle:      vum_rec.memory[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_MEMORY,
              object_id: '0,
              handle: vum_rec.memory[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVbm: if (vbm_rdy) state_q <= WaitVbm;
        WaitVbm: if (vbm_cpl) begin
          if (vbm_c.status != APU_VBM_OK || !vbm_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b1,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vbm_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_BUFFER,
              object_id:   '0,
              handle:      vbm_rec.buffer[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_BUFFER,
              object_id: '0,
              handle: vbm_rec.buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVfm: if (vfm_rdy) state_q <= WaitVfm;
        WaitVfm: if (vfm_cpl) begin
          if (vfm_c.status != APU_VFM_OK || !vfm_rec.valid || !map_ok_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b1,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vfm_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_MEMORY,
              object_id:   '0,
              handle:      vfm_rec.memory[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_MEMORY,
              object_id: '0,
              handle: vfm_rec.memory[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVim: if (vim_rdy) state_q <= WaitVim;
        WaitVim: if (vim_cpl) begin
          if (vim_c.status != APU_VIM_OK || !vim_rec.valid || !map_ok_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b1,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vim_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_MEMORY,
              object_id:   '0,
              handle:      vim_rec.memory[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_MEMORY,
              object_id: '0,
              handle: vim_rec.memory[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVmc: if (vmc_rdy) state_q <= WaitVmc;
        WaitVmc: if (vmc_cpl) begin
          if (vmc_c.status != APU_VMC_OK || !vmc_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b1,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vmc_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_MEMORY,
              object_id:   '0,
              handle:      vmc_rec.memory[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_MEMORY,
              object_id: '0,
              handle: vmc_rec.memory[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVdl: if (vdl_rdy) state_q <= WaitVdl;
        WaitVdl: if (vdl_cpl) begin
          if (vdl_c.status != APU_VDL_OK || !vdl_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b1,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vdl_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_DEVICE,
              object_id:   vdl_rec.guest[31:0],
              handle:      vdl_rec.device[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_DEVICE,
              object_id: '0,
              handle: vdl_rec.device[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVpl: if (vpl_rdy) state_q <= WaitVpl;
        WaitVpl: if (vpl_cpl) begin
          if (vpl_c.status != APU_VPL_OK || !vpl_rec.valid || !dsl_ok_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b1,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vpl_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_DEVICE,
              object_id:   vpl_rec.guest[31:0],
              handle:      vpl_rec.device[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_DEVICE,
              object_id: '0,
              handle: vpl_rec.device[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVcp: if (vcp_rdy) state_q <= WaitVcp;
        WaitVcp: if (vcp_cpl) begin
          if (vcp_c.status != APU_VCP_OK || !vcp_rec.valid || !pl_ok_q ||
              !loaded_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b1,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vcp_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_DEVICE,
              object_id:   vcp_rec.guest[31:0],
              handle:      vcp_rec.device[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_DEVICE,
              object_id: '0,
              handle: vcp_rec.device[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVda: if (vda_rdy) state_q <= WaitVda;
        WaitVda: if (vda_cpl) begin
          if (vda_c.status != APU_VDA_OK || !vda_rec.valid || !dsl_ok_q ||
              !pool_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b1,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded: loaded_q, begun: begun_q, reply: vda_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: vda_rec.guest[31:0], handle: vda_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            pool_h_q <= vda_rec.pool[31:0];
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vda_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVud: if (vud_rdy) state_q <= WaitVud;
        WaitVud: if (vud_cpl) begin
          if (vud_c.status != APU_VUD_OK || !vud_rec.valid || !dset_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b1, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded: loaded_q, begun: begun_q, reply: vud_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DESCSET,
              object_id: vud_rec.buffer[31:0], handle: vud_rec.dset[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DESCSET, object_id: '0,
                           handle: vud_rec.dset[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVbp: if (vbp_rdy) state_q <= WaitVbp;
        WaitVbp: if (vbp_cpl) begin
          if (vbp_c.status != APU_VBP_OK || !vbp_rec.valid || !begun_q ||
              vbp_rec.cbuf[31:0] != begun_handle_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b1, bind_desc: 1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded: loaded_q, begun: begun_q, reply: vbp_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_PIPELINE,
              object_id: '0, handle: vbp_rec.pipeline[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_PIPELINE, object_id: '0,
                           handle: vbp_rec.pipeline[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVbd: if (vbd_rdy) state_q <= WaitVbd;
        WaitVbd: if (vbd_cpl) begin
          if (vbd_c.status != APU_VBD_OK || !vbd_rec.valid || !begun_q ||
              !dset_ok_q || vbd_rec.cbuf[31:0] != begun_handle_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b1,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded: loaded_q, begun: begun_q, reply: vbd_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DESCSET,
              object_id: '0, handle: vbd_rec.dset[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DESCSET, object_id: '0,
                           handle: vbd_rec.dset[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVcd: if (vcd_rdy) state_q <= WaitVcd;
        WaitVcd: if (vcd_cpl) begin
          if (vcd_c.status != APU_VCD_OK || !vcd_rec.valid ||
              !qfam_ok_q || !feat_ok_q || !props_ok_q || !mem_ok_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b1,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vcd_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_PHYS,
              object_id:   '0,
              handle:      vcd_rec.physical_device[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_PHYS,
              object_id: '0,
              handle: vcd_rec.physical_device[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVci: if (vci_rdy) state_q <= WaitVci;
        WaitVci: if (vci_cpl) begin
          if (vci_c.status != APU_VCI_OK || !vci_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b1,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vci_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_INSTANCE,
              object_id:   vci_rec.info[31:0],
              handle:      '0,
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_INSTANCE,
              object_id: vci_rec.info[31:0],
              handle: '0
            };
            look_q <= 1'b0;
            state_q <= FireGnh;
          end
        end
        FireVep: if (vep_rdy) state_q <= WaitVep;
        WaitVep: if (vep_cpl) begin
          if (vep_c.status != APU_VEP_OK || !vep_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b1,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vep_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_INSTANCE,
              object_id:   '0,
              handle:      vep_rec.instance_handle[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_INSTANCE,
              object_id: '0,
              handle: vep_rec.instance_handle[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVqf: if (vqf_rdy) state_q <= WaitVqf;
        WaitVqf: if (vqf_cpl) begin
          if (vqf_c.status != APU_VQF_OK || !vqf_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b1,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vqf_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_PHYS,
              object_id:   '0,
              handle:      vqf_rec.phys_handle[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_PHYS,
              object_id: '0,
              handle: vqf_rec.phys_handle[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVpf: if (vpf_rdy) state_q <= WaitVpf;
        WaitVpf: if (vpf_cpl) begin
          if (vpf_c.status != APU_VPF_OK || !vpf_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b1,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vpf_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_PHYS,
              object_id:   '0,
              handle:      vpf_rec.phys_handle[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_PHYS,
              object_id: '0,
              handle: vpf_rec.phys_handle[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVpp: if (vpp_rdy) state_q <= WaitVpp;
        WaitVpp: if (vpp_cpl) begin
          if (vpp_c.status != APU_VPP_OK || !vpp_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b1,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vpp_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_PHYS,
              object_id:   '0,
              handle:      vpp_rec.phys_handle[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_PHYS,
              object_id: '0,
              handle: vpp_rec.phys_handle[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVmp: if (vmp_rdy) state_q <= WaitVmp;
        WaitVmp: if (vmp_cpl) begin
          if (vmp_c.status != APU_VMP_OK || !vmp_rec.valid) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b1,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       vmp_rec.reply,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_PHYS,
              object_id:   '0,
              handle:      vmp_rec.phys_handle[31:0],
              begin_flags: begin_flags_q,
              code_words:  '0,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_PHYS,
              object_id: '0,
              handle: vmp_rec.phys_handle[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireVpo: if (vpo_rdy) state_q <= WaitVpo;
        WaitVpo: if (vpo_cpl) begin
          if (vpo_c.status != APU_VPO_OK || !vpo_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b1, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vpo_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: vpo_rec.guest[31:0], handle: vpo_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vpo_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVxi: if (vxi_rdy) state_q <= WaitVxi;
        WaitVxi: if (vxi_cpl) begin
          if (vxi_c.status != APU_VXI_OK || !vxi_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b1, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vxi_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: vxi_rec.guest[31:0], handle: vxi_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vxi_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVbi: if (vbi_rdy) state_q <= WaitVbi;
        WaitVbi: if (vbi_cpl) begin
          if (vbi_c.status != APU_VBI_OK || !vbi_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b1, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vbi_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_IMAGE,
              object_id: vbi_rec.memory[31:0], handle: vbi_rec.image[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vbi_rec.image[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVmi: if (vmi_rdy) state_q <= WaitVmi;
        WaitVmi: if (vmi_cpl) begin
          if (vmi_c.status != APU_VMI_OK || !vmi_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b1,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vmi_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_IMAGE,
              object_id: '0, handle: vmi_rec.image[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vmi_rec.image[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVxv: if (vxv_rdy) state_q <= WaitVxv;
        WaitVxv: if (vxv_cpl) begin
          if (vxv_c.status != APU_VXV_OK || !vxv_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b1, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vxv_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_IMAGE,
              object_id: vxv_rec.guest[31:0], handle: vxv_rec.image[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vxv_rec.image[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVsm: if (vsm_rdy) state_q <= WaitVsm;
        WaitVsm: if (vsm_cpl) begin
          if (vsm_c.status != APU_VSM_OK || !vsm_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b1, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vsm_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: vsm_rec.guest[31:0], handle: vsm_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vsm_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVrp: if (vrp_rdy) state_q <= WaitVrp;
        WaitVrp: if (vrp_cpl) begin
          if (vrp_c.status != APU_VRP_OK || !vrp_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b1, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vrp_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: vrp_rec.guest[31:0], handle: vrp_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vrp_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVgp: if (vgp_rdy) state_q <= WaitVgp;
        WaitVgp: if (vgp_cpl) begin
          if (vgp_c.status != APU_VGP_OK || !vgp_rec.valid || !rp_ok_q ||
              !pl_ok_q || !loaded_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b1,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vgp_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: vgp_rec.guest[31:0], handle: vgp_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vgp_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVfb: if (vfb_rdy) state_q <= WaitVfb;
        WaitVfb: if (vfb_cpl) begin
          if (vfb_c.status != APU_VFB_OK || !vfb_rec.valid || !rp_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b1, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vfb_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: vfb_rec.guest[31:0], handle: vfb_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vfb_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVrb: if (vrb_rdy) state_q <= WaitVrb;
        WaitVrb: if (vrb_cpl) begin
          if (vrb_c.status != APU_VRB_OK || !vrb_rec.valid || !begun_q ||
              !fbuf_ok_q || !rp_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b1, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vrb_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vrb_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vrb_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdw: if (vdw_rdy) state_q <= WaitVdw;
        WaitVdw: if (vdw_cpl) begin
          if (vdw_c.status != APU_VDW_OK || !vdw_rec.valid || !begun_q ||
              !in_rp_q || !pipe_bound_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b1, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdw_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vdw_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: vdw_rec.vcount
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vdw_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVre: if (vre_rdy) state_q <= WaitVre;
        WaitVre: if (vre_cpl) begin
          if (vre_c.status != APU_VRE_OK || !vre_rec.valid || !in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b1,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vre_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vre_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vre_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVvb: if (vvb_rdy) state_q <= WaitVvb;
        WaitVvb: if (vvb_cpl) begin
          if (vvb_c.status != APU_VVB_OK || !vvb_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b1, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vvb_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: vvb_rec.buffer[31:0], handle: vvb_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vvb_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVib: if (vib_rdy) state_q <= WaitVib;
        WaitVib: if (vib_cpl) begin
          if (vib_c.status != APU_VIB_OK || !vib_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b1, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vib_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: vib_rec.buffer[31:0], handle: vib_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vib_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdi: if (vdi_rdy) state_q <= WaitVdi;
        WaitVdi: if (vdi_cpl) begin
          if (vdi_c.status != APU_VDI_OK || !vdi_rec.valid || !begun_q ||
              !in_rp_q || !pipe_bound_q || !idx_bound_q || !vtx_bound_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b1,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdi_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vdi_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: vdi_rec.icount
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vdi_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVvp: if (vvp_rdy) state_q <= WaitVvp;
        WaitVvp: if (vvp_cpl) begin
          if (vvp_c.status != APU_VVP_OK || !vvp_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b1, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vvp_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vvp_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vvp_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVsi: if (vsi_rdy) state_q <= WaitVsi;
        WaitVsi: if (vsi_cpl) begin
          if (vsi_c.status != APU_VSI_OK || !vsi_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b1, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vsi_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vsi_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vsi_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVpb: if (vpb_rdy) state_q <= WaitVpb;
        WaitVpb: if (vpb_cpl) begin
          if (vpb_c.status != APU_VPB_OK || !vpb_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b1, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vpb_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vpb_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vpb_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVns: if (vns_rdy) state_q <= WaitVns;
        WaitVns: if (vns_cpl) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
        end
        FireVdf: if (vdf_rdy) state_q <= WaitVdf;
        WaitVdf: if (vdf_cpl) begin
          if (vdf_c.status != APU_DFB_OK || !vdf_rec.valid || !fbuf_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b1, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdf_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_FBUF,
              object_id: '0, handle: vdf_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_FBUF, object_id: '0,
                           handle: vdf_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdx: if (vdx_rdy) state_q <= WaitVdx;
        WaitVdx: if (vdx_cpl) begin
          if (vdx_c.status != APU_DVW_OK || !vdx_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b1, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdx_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_VIEW,
              object_id: '0, handle: vdx_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_VIEW, object_id: '0,
                           handle: vdx_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdk: if (vdk_rdy) state_q <= WaitVdk;
        WaitVdk: if (vdk_cpl) begin
          if (vdk_c.status != APU_DSM_OK || !vdk_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b1, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdk_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_SAMPLER,
              object_id: '0, handle: vdk_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_SAMPLER, object_id: '0,
                           handle: vdk_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdr: if (vdr_rdy) state_q <= WaitVdr;
        WaitVdr: if (vdr_cpl) begin
          if (vdr_c.status != APU_DRP_OK || !vdr_rec.valid || !rp_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b1,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdr_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_RPASS,
              object_id: '0, handle: vdr_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_RPASS, object_id: '0,
                           handle: vdr_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdb: if (vdb_rdy) state_q <= WaitVdb;
        WaitVdb: if (vdb_cpl) begin
          if (vdb_c.status != APU_DBF_OK || !vdb_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b1, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdb_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_BUFFER,
              object_id: '0, handle: vdb_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vdb_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdg: if (vdg_rdy) state_q <= WaitVdg;
        WaitVdg: if (vdg_cpl) begin
          if (vdg_c.status != APU_DIM_OK || !vdg_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b1, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdg_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_IMAGE,
              object_id: '0, handle: vdg_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vdg_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVfe: if (vfe_rdy) state_q <= WaitVfe;
        WaitVfe: if (vfe_cpl) begin
          if (vfe_c.status != APU_FME_OK || !vfe_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b1, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vfe_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_MEMORY,
              object_id: '0, handle: vfe_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_MEMORY, object_id: '0,
                           handle: vfe_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdm: if (vdm_rdy) state_q <= WaitVdm;
        WaitVdm: if (vdm_cpl) begin
          if (vdm_c.status != APU_DMD_OK || !vdm_rec.valid || !loaded_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b1,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdm_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_MODULE,
              object_id: '0, handle: vdm_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_MODULE, object_id: '0,
                           handle: vdm_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdp: if (vdp_rdy) state_q <= WaitVdp;
        WaitVdp: if (vdp_cpl) begin
          if (vdp_c.status != APU_DPL_OK || !vdp_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b1, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdp_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_PIPELINE,
              object_id: '0, handle: vdp_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_PIPELINE, object_id: '0,
                           handle: vdp_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdy: if (vdy_rdy) state_q <= WaitVdy;
        WaitVdy: if (vdy_cpl) begin
          if (vdy_c.status != APU_DYO_OK || !vdy_rec.valid || !pl_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b1, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdy_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_PLAYOUT,
              object_id: '0, handle: vdy_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_PLAYOUT, object_id: '0,
                           handle: vdy_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdt: if (vdt_rdy) state_q <= WaitVdt;
        WaitVdt: if (vdt_cpl) begin
          if (vdt_c.status != APU_DDS_OK || !vdt_rec.valid || !dsl_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b1, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdt_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DSLAYOUT,
              object_id: '0, handle: vdt_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DSLAYOUT, object_id: '0,
                           handle: vdt_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdq: if (vdq_rdy) state_q <= WaitVdq;
        WaitVdq: if (vdq_cpl) begin
          if (vdq_c.status != APU_DPO_OK || !vdq_rec.valid || !pool_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b1,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdq_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_POOL,
              object_id: '0, handle: vdq_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_POOL, object_id: '0,
                           handle: vdq_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVfs: if (vfs_rdy) state_q <= WaitVfs;
        WaitVfs: if (vfs_cpl) begin
          if (vfs_c.status != APU_FDS_OK || !vfs_rec.valid || !dset_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b1, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vfs_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DESCSET,
              object_id: '0, handle: vfs_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DESCSET, object_id: '0,
                           handle: vfs_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVrc: if (vrc_rdy) state_q <= WaitVrc;
        WaitVrc: if (vrc_cpl) begin
          if (vrc_c.status != APU_RCB_OK || !vrc_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b1, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vrc_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vrc_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vrc_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVfc: if (vfc_rdy) state_q <= WaitVfc;
        WaitVfc: if (vfc_cpl) begin
          if (vfc_c.status != APU_FCB_OK || !vfc_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b1, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vfc_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vfc_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vfc_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdd: if (vdd_rdy) state_q <= WaitVdd;
        WaitVdd: if (vdd_cpl) begin
          if (vdd_c.status != APU_DDV_OK || !vdd_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b1,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdd_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vdd_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vdd_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVpc: if (vpc_rdy) state_q <= WaitVpc;
        WaitVpc: if (vpc_cpl) begin
          if (vpc_c.status != APU_RCP_OK || !vpc_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b1, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vpc_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vpc_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vpc_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdc: if (vdc_rdy) state_q <= WaitVdc;
        WaitVdc: if (vdc_cpl) begin
          if (vdc_c.status != APU_DCP_OK || !vdc_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b1, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdc_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vdc_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vdc_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVdn: if (vdn_rdy) state_q <= WaitVdn;
        WaitVdn: if (vdn_cpl) begin
          if (vdn_c.status != APU_DIN_OK || !vdn_rec.valid || !instanced_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b1,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vdn_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_INSTANCE,
              object_id: '0, handle: vdn_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_INSTANCE, object_id: '0,
                           handle: vdn_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVgf: if (vgf_rdy) state_q <= WaitVgf;
        WaitVgf: if (vgf_cpl) begin
          if (vgf_c.status != APU_GFP_OK || !vgf_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b1, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vgf_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_PHYS,
              object_id: '0, handle: vgf_rec.phys_handle[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_PHYS, object_id: '0,
                           handle: vgf_rec.phys_handle[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVip: if (vip_rdy) state_q <= WaitVip;
        WaitVip: if (vip_cpl) begin
          if (vip_c.status != APU_IFP_OK || !vip_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b1, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vip_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_PHYS,
              object_id: '0, handle: vip_rec.phys_handle[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_PHYS, object_id: '0,
                           handle: vip_rec.phys_handle[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVxe: if (vxe_rdy) state_q <= WaitVxe;
        WaitVxe: if (vxe_cpl) begin
          if (vxe_c.status != APU_DEX_OK || !vxe_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b1, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vxe_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_PHYS,
              object_id: '0, handle: vxe_rec.phys_handle[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_PHYS, object_id: '0,
                           handle: vxe_rec.phys_handle[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVrd: if (vrd_rdy) state_q <= WaitVrd;
        WaitVrd: if (vrd_cpl) begin
          if (vrd_c.status != APU_RDP_OK || !vrd_rec.valid || !pool_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b1,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vrd_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_POOL,
              object_id: '0, handle: vrd_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_POOL, object_id: '0,
                           handle: vrd_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVie: if (vie_rdy) state_q <= WaitVie;
        WaitVie: if (vie_cpl) begin
          if (vie_c.status != APU_IEX_OK || !vie_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b1, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vie_rec.reply,
              slot: '0, gen: '0, kind: apu_gnh_kind_e'('0),
              object_id: '0, handle: '0,
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: APU_IEX_COUNT
            };
            if (vie_rec.reply) begin
              tail_q[0] <= APU_IEX_CMD_IEX; tail_q[1] <= 32'd0;
              tail_q[2] <= APU_IEX_COUNT; tail_q[3] <= 32'd0;
              tail_q[4] <= 32'd0; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end
        end
        FireVwl: if (vwl_rdy) state_q <= WaitVwl;
        WaitVwl: if (vwl_cpl) begin
          if (vwl_c.status != APU_DWI_OK || !vwl_rec.valid || !submitted_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b1, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vwl_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vwl_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vwl_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVsl: if (vsl_rdy) state_q <= WaitVsl;
        WaitVsl: if (vsl_cpl) begin
          if (vsl_c.status != APU_ISL_OK || !vsl_rec.valid) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b1, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vsl_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_IMAGE,
              object_id: '0, handle: vsl_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vsl_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVrg: if (vrg_rdy) state_q <= WaitVrg;
        WaitVrg: if (vrg_cpl) begin
          if (vrg_c.status != APU_RAG_OK || !vrg_rec.valid || !rp_ok_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b1,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vrg_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_RPASS,
              object_id: '0, handle: vrg_rec.obj[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_RPASS, object_id: '0,
                           handle: vrg_rec.obj[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVlw: if (vlw_rdy) state_q <= WaitVlw;
        WaitVlw: if (vlw_cpl) begin
          if (vlw_c.status != APU_SLW_OK || !vlw_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b1, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vlw_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vlw_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vlw_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVzb: if (vzb_rdy) state_q <= WaitVzb;
        WaitVzb: if (vzb_cpl) begin
          if (vzb_c.status != APU_SDB_OK || !vzb_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b1, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vzb_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vzb_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vzb_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVbc: if (vbc_rdy) state_q <= WaitVbc;
        WaitVbc: if (vbc_cpl) begin
          if (vbc_c.status != APU_SBC_OK || !vbc_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b1, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vbc_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vbc_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vbc_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVbo: if (vbo_rdy) state_q <= WaitVbo;
        WaitVbo: if (vbo_cpl) begin
          if (vbo_c.status != APU_SBB_OK || !vbo_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b1,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vbo_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vbo_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vbo_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVcm: if (vcm_rdy) state_q <= WaitVcm;
        WaitVcm: if (vcm_cpl) begin
          if (vcm_c.status != APU_SCM_OK || !vcm_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b1, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vcm_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vcm_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vcm_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVwm: if (vwm_rdy) state_q <= WaitVwm;
        WaitVwm: if (vwm_cpl) begin
          if (vwm_c.status != APU_SWM_OK || !vwm_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b1, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vwm_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vwm_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vwm_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVrf: if (vrf_rdy) state_q <= WaitVrf;
        WaitVrf: if (vrf_cpl) begin
          if (vrf_c.status != APU_SRF_OK || !vrf_rec.valid || !begun_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b1,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vrf_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vrf_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vrf_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVcc: if (vcc_rdy) state_q <= WaitVcc;
        WaitVcc: if (vcc_cpl) begin
          if (vcc_c.status != APU_CCB_OK || !vcc_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b1, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vcc_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vcc_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vcc_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVcy: if (vcy_rdy) state_q <= WaitVcy;
        WaitVcy: if (vcy_cpl) begin
          if (vcy_c.status != APU_CCI_OK || !vcy_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b1, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vcy_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vcy_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vcy_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVbl: if (vbl_rdy) state_q <= WaitVbl;
        WaitVbl: if (vbl_cpl) begin
          if (vbl_c.status != APU_BLI_OK || !vbl_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b1, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vbl_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vbl_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vbl_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVbt: if (vbt_rdy) state_q <= WaitVbt;
        WaitVbt: if (vbt_cpl) begin
          if (vbt_c.status != APU_CBI_OK || !vbt_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b1,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vbt_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vbt_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vbt_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVic: if (vic_rdy) state_q <= WaitVic;
        WaitVic: if (vic_cpl) begin
          if (vic_c.status != APU_CIB_OK || !vic_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b1, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vic_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vic_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vic_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVub: if (vub_rdy) state_q <= WaitVub;
        WaitVub: if (vub_cpl) begin
          if (vub_c.status != APU_UBF_OK || !vub_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b1, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vub_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vub_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vub_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVfl: if (vfl_rdy) state_q <= WaitVfl;
        WaitVfl: if (vfl_cpl) begin
          if (vfl_c.status != APU_FIL_OK || !vfl_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b1, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vfl_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vfl_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vfl_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVcl: if (vcl_rdy) state_q <= WaitVcl;
        WaitVcl: if (vcl_cpl) begin
          if (vcl_c.status != APU_CCL_OK || !vcl_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b1,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vcl_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vcl_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vcl_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVio: if (vio_rdy) state_q <= WaitVio;
        WaitVio: if (vio_cpl) begin
          if (vio_c.status != APU_DRI_OK || !vio_rec.valid || !begun_q || !in_rp_q || !pipe_bound_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b1, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vio_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vio_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vio_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVix: if (vix_rdy) state_q <= WaitVix;
        WaitVix: if (vix_cpl) begin
          if (vix_c.status != APU_IXI_OK || !vix_rec.valid || !begun_q || !in_rp_q || !pipe_bound_q || !idx_bound_q || !vtx_bound_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b1, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vix_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vix_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vix_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVds: if (vds_rdy) state_q <= WaitVds;
        WaitVds: if (vds_cpl) begin
          if (vds_c.status != APU_CDS_OK || !vds_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b1, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vds_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vds_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vds_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVat: if (vat_rdy) state_q <= WaitVat;
        WaitVat: if (vat_cpl) begin
          if (vat_c.status != APU_CAT_OK || !vat_rec.valid || !begun_q || !in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b1,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vat_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vat_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vat_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVin: if (vin_rdy) state_q <= WaitVin;
        WaitVin: if (vin_cpl) begin
          if (vin_c.status != APU_DSI_OK || !vin_rec.valid || !begun_q || in_rp_q || !pipe_bound_q || !desc_bound_q || !loaded_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b1, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vin_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vin_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vin_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVrs: if (vrs_rdy) state_q <= WaitVrs;
        WaitVrs: if (vrs_cpl) begin
          if (vrs_c.status != APU_RSI_OK || !vrs_rec.valid || !begun_q || in_rp_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b1,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vrs_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_CMDBUF,
              object_id: '0, handle: vrs_rec.cbuf[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: vrs_rec.cbuf[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVgs: if (vgs_rdy) state_q <= WaitVgs;
        WaitVgs: if (vgs_cpl) begin
          if (vgs_c.status != APU_GFS_OK || !vgs_rec.valid ) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b1, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vgs_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vgs_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vgs_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVwf: if (vwf_rdy) state_q <= WaitVwf;
        WaitVwf: if (vwf_cpl) begin
          if (vwf_c.status != APU_WFE_OK || !vwf_rec.valid || !submitted_q) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b1, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vwf_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vwf_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vwf_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVfr: if (vfr_rdy) state_q <= WaitVfr;
        WaitVfr: if (vfr_cpl) begin
          if (vfr_c.status != APU_RFE_OK || !vfr_rec.valid ) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b1, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: vfr_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vfr_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vfr_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireVfn: if (vfn_rdy) state_q <= WaitVfn;
        WaitVfn: if (vfn_cpl) begin
          if (vfn_c.status != APU_DFE_OK || !vfn_rec.valid ) begin
            rec_q <= '0; cpl_q <= '{status: APU_BRU_FAULT}; state_q <= Done;
          end else begin
            rec_q <= '{
              valid: 1'b0, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0, create: 1'b0,
              dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0, get_queue: 1'b0,
              create_device: 1'b0, create_instance: 1'b0, enum_phys: 1'b0,
              get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0, get_mem: 1'b0,
              alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b1,
              loaded: loaded_q, begun: begun_q, reply: vfn_rec.reply,
              slot: '0, gen: '0, kind: APU_GNH_DEVICE,
              object_id: '0, handle: vfn_rec.device[31:0],
              begin_flags: begin_flags_q, code_words: '0, group_x: '0, group_y: '0,
              group_z: '0, result: '0
            };
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: vfn_rec.device[31:0]};
            look_q <= 1'b1; state_q <= FireGnh;
          end
        end
        FireEnc: if (enc_rdy) state_q <= WaitEnc;
        WaitEnc: if (enc_cpl) begin
          if (enc_c.status != APU_VNENC_OK || !enc_rec.valid ||
              enc_rec.first_word != APU_SPIRV_MAGIC ||
              enc_rec.module_id[63:32] != 32'd0 ||
              enc_rec.module_id[31:0] == 32'd0 ||
              enc_rec.code_words == 32'd0 ||
              enc_rec.code_words > 32'(APU_VNENC_MAX_WORDS)) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b1,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:  1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      1'b0,
              begun:       begun_q,
              reply:       1'b0,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_MODULE,
              object_id:   enc_rec.module_id[31:0],
              handle:      '0,
              begin_flags: begin_flags_q,
              code_words:  enc_rec.code_words,
              group_x:     '0,
              group_y:     '0,
              group_z:     '0,
              result:      '0
            };
            n_q <= enc_rec.code_words[7:0];
            load_q <= '0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_MODULE,
              object_id: enc_rec.module_id[31:0],
              handle: '0
            };
            state_q <= FireGnh;
          end
        end
        FireVnd: if (vnd_rdy) state_q <= WaitVnd;
        WaitVnd: if (vnd_cpl) begin
          if (vnd_c.status != APU_VND_OK || !vnd_rec.valid ||
              vnd_rec.command_buffer[63:32] != 32'd0 ||
              vnd_rec.command_buffer[31:0] != begun_handle_q) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       1'b0,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b1,
              submit:      1'b0,
              wait_idle:  1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       1'b1,
              reply:       1'b0,
              slot:        '0,
              gen:         '0,
              kind:        APU_GNH_CMDBUF,
              object_id:   '0,
              handle:      vnd_rec.command_buffer[31:0],
              begin_flags: begin_flags_q,
              code_words:  rec_q.code_words,
              group_x:     vnd_rec.group_x,
              group_y:     vnd_rec.group_y,
              group_z:     vnd_rec.group_z,
              result:      '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: vnd_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireGnh: if (gnh_rdy) state_q <= WaitGnh;
        WaitGnh: if (gnh_cpl) begin
          if (gnh_c.status != APU_GNH_OK ||
              (look_q && (queue_q || vkmem_q || buffer_q || dsl_q || pl_q ||
                          cpipe_q || pool_q || img_q || samp_q || rpass_q ||
                          gpipe_q || fbuf_q || (dset_q && !dset_pool_q)) &&
               gnh_rec.kind != APU_GNH_DEVICE) ||
              (look_q && (bind_q && !bind_mem_q || bufreq_q) &&
               gnh_rec.kind != APU_GNH_BUFFER) ||
              (look_q && bind_q && bind_mem_q &&
               gnh_rec.kind != APU_GNH_MEMORY) ||
              (look_q && dset_q && dset_pool_q &&
               gnh_rec.kind != APU_GNH_POOL) ||
              (look_q && (bindimg_q && !bindimg_mem_q || imgreq_q || view_q) &&
               gnh_rec.kind != APU_GNH_IMAGE) ||
              (look_q && bindimg_q && bindimg_mem_q &&
               gnh_rec.kind != APU_GNH_MEMORY) ||
              (look_q && (vtx_q && !vtx_buf_q || idxb_q && !idx_buf_q ||
                          drawi_q || vp_q || sc_q || bar_q || slw_q || sdb_q || sbc_q || sbb_q || scm_q || swm_q || srf_q ||
                          (cat_q || ((ccb_q || cci_q || bli_q || cbi_q || cib_q || ubu_q || fil_q || ccl_q || dinr_q || didi_q || cds_q || dsi_q || rsl_q) && !copy_src_q))) && gnh_rec.kind != APU_GNH_CMDBUF) ||
              (look_q && dfb_q && !dfb_ret_q && gnh_rec.kind != APU_GNH_FBUF) ||
              (look_q && dvw_q && !dvw_ret_q && gnh_rec.kind != APU_GNH_VIEW) ||
              (look_q && dsm_q && !dsm_ret_q && gnh_rec.kind != APU_GNH_SAMPLER) ||
              (look_q && drp_q && !drp_ret_q && gnh_rec.kind != APU_GNH_RPASS) ||
              (look_q && dbf_q && !dbf_ret_q && gnh_rec.kind != APU_GNH_BUFFER) ||
              (look_q && dim_q && !dim_ret_q && gnh_rec.kind != APU_GNH_IMAGE) ||
              (look_q && fme_q && !fme_ret_q && gnh_rec.kind != APU_GNH_MEMORY) ||
              (look_q && dmd_q && !dmd_ret_q && gnh_rec.kind != APU_GNH_MODULE) ||
              (look_q && dpl_q && !dpl_ret_q && gnh_rec.kind != APU_GNH_PIPELINE) ||
              (look_q && dyo_q && !dyo_ret_q && gnh_rec.kind != APU_GNH_PLAYOUT) ||
              (look_q && dds_q && !dds_ret_q && gnh_rec.kind != APU_GNH_DSLAYOUT) ||
              (look_q && dpo_q && !dpo_ret_q && gnh_rec.kind != APU_GNH_POOL) ||
              (look_q && rdp_q && gnh_rec.kind != APU_GNH_POOL) ||
              (look_q && dwi_q && gnh_rec.kind != APU_GNH_DEVICE) ||
              (look_q && (gfs_q || wfe_q || rfe_q || dfe_q) && gnh_rec.kind != APU_GNH_DEVICE) ||
              (look_q && isl_q && gnh_rec.kind != APU_GNH_IMAGE) ||
              (look_q && rag_q && gnh_rec.kind != APU_GNH_RPASS) ||
              (look_q && fds_q && !fds_ret_q && gnh_rec.kind != APU_GNH_DESCSET) ||
              (look_q && ddv_q && !ddv_ret_q && gnh_rec.kind != APU_GNH_DEVICE) ||
              (look_q && rcp_q && gnh_rec.kind != APU_GNH_DEVICE) ||
              (look_q && dcp_q && gnh_rec.kind != APU_GNH_DEVICE) ||
              (look_q && din_q && !din_ret_q && gnh_rec.kind != APU_GNH_INSTANCE) ||
              (look_q && (vtx_q && vtx_buf_q || idxb_q && idx_buf_q) &&
               gnh_rec.kind != APU_GNH_BUFFER) ||
              (look_q && (ccb_q || cbi_q || ubu_q || fil_q || dinr_q || didi_q || dsi_q) && copy_src_q && !copy_dst_q &&
               gnh_rec.kind != APU_GNH_BUFFER) ||
              (look_q && (cci_q || bli_q || cib_q || ccl_q || cds_q || rsl_q) && copy_src_q && !copy_dst_q &&
               gnh_rec.kind != APU_GNH_IMAGE) ||
              (look_q && (ccb_q || cib_q) && copy_dst_q &&
               gnh_rec.kind != APU_GNH_BUFFER) ||
              (look_q && (cci_q || bli_q || cbi_q || rsl_q) && copy_dst_q &&
               gnh_rec.kind != APU_GNH_IMAGE) ||
              (look_q && upd_q && !upd_buf_q &&
               gnh_rec.kind != APU_GNH_DESCSET) ||
              (look_q && upd_q && upd_buf_q &&
               gnh_rec.kind != APU_GNH_BUFFER) ||
              (look_q && bp_q && gnh_rec.kind != APU_GNH_PIPELINE) ||
              (look_q && bd_q && gnh_rec.kind != APU_GNH_DESCSET) ||
              (look_q && (map_q || unmap_q || flush_q || inval_q || memc_q) &&
               gnh_rec.kind != APU_GNH_MEMORY) ||
              (look_q && (device_q || qfam_q || feat_q || props_q || mem_q || fmt_q || ifmt_q || dext_q) &&
               gnh_rec.kind != APU_GNH_PHYS) ||
              (look_q && enum_q && gnh_rec.kind != APU_GNH_INSTANCE) ||
              (look_q && !queue_q && !vkmem_q && !buffer_q && !bind_q &&
               !map_q && !unmap_q && !bufreq_q && !flush_q && !inval_q &&
               !memc_q && !dsl_q && !pl_q && !cpipe_q && !dset_q &&
               !upd_q && !bp_q && !bd_q && !pool_q && !img_q &&
               !bindimg_q && !imgreq_q && !view_q && !samp_q &&
               !rpass_q && !gpipe_q && !fbuf_q && !beginrp_q &&
               !draw_q && !endrp_q && !vtx_q && !idxb_q && !drawi_q && !vp_q && !sc_q && !bar_q && !dfb_q && !dvw_q && !dsm_q && !drp_q && !dbf_q && !dim_q && !fme_q && !dmd_q && !dpl_q && !dyo_q && !dds_q && !dpo_q && !fds_q && !ddv_q && !rcp_q && !dcp_q && !din_q && !fmt_q && !ifmt_q && !dext_q && !rdp_q && !dwi_q && !isl_q && !rag_q && !slw_q && !sdb_q && !sbc_q && !sbb_q && !scm_q && !swm_q && !srf_q && !ccb_q && !cci_q && !bli_q && !cbi_q && !cib_q && !ubu_q && !fil_q && !ccl_q && !dinr_q && !didi_q && !cds_q && !cat_q && !dsi_q && !rsl_q && !gfs_q && !wfe_q && !rfe_q && !dfe_q && !device_q &&
               !enum_q && !qfam_q && !feat_q && !props_q && !mem_q &&
               gnh_rec.kind != APU_GNH_CMDBUF) ||
              (end_q && (!begun_q || gnh_rec.handle != begun_handle_q)) ||
              (beginrp_q && gnh_rec.handle != begun_handle_q) ||
              (draw_q && gnh_rec.handle != begun_handle_q) ||
              (endrp_q && gnh_rec.handle != begun_handle_q) ||
              ((vtx_q && !vtx_buf_q || idxb_q && !idx_buf_q || drawi_q ||
                vp_q || sc_q || bar_q || slw_q || sdb_q || sbc_q || sbb_q || scm_q || swm_q || srf_q ||
                (cat_q || ((ccb_q || cci_q || bli_q || cbi_q || cib_q || ubu_q || fil_q || ccl_q || dinr_q || didi_q || cds_q || dsi_q || rsl_q) && !copy_src_q))) &&
               gnh_rec.handle != begun_handle_q) ||
              (submit_q && (!ended_q || gnh_rec.handle != ended_handle_q ||
                            !queued_q ||
                            vqs_rec.queue_handle[31:0] != queue_handle_q))) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else if (queue_q && look_q) begin
            look_q <= 1'b0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_QUEUE,
              object_id: gnh_rec.handle,
              handle: '0
            };
            state_q <= FireGnh;
          end else if (vkmem_q && look_q) begin
            look_q <= 1'b0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_MEMORY,
              object_id: rec_q.object_id,
              handle: '0
            };
            state_q <= FireGnh;
          end else if (buffer_q && look_q) begin
            look_q <= 1'b0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_BUFFER,
              object_id: rec_q.object_id,
              handle: '0
            };
            state_q <= FireGnh;
          end else if ((dsl_q || pl_q || cpipe_q || pool_q || img_q ||
                        samp_q || rpass_q || gpipe_q || view_q || fbuf_q) && look_q) begin
            look_q <= 1'b0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: dsl_q ? APU_GNH_DSLAYOUT :
                    (pl_q ? APU_GNH_PLAYOUT :
                     (cpipe_q ? APU_GNH_PIPELINE :
                      (pool_q ? APU_GNH_POOL :
                       (img_q ? APU_GNH_IMAGE :
                        (samp_q ? APU_GNH_SAMPLER :
                         (rpass_q ? APU_GNH_RPASS :
                          (gpipe_q ? APU_GNH_PIPELINE :
                           (view_q ? APU_GNH_VIEW : APU_GNH_FBUF)))))))),
              object_id: rec_q.object_id,
              handle: '0
            };
            state_q <= FireGnh;
          end else if (dset_q && look_q && !dset_pool_q) begin
            dset_pool_q <= 1'b1;
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP, kind: APU_GNH_POOL, object_id: '0,
              handle: pool_h_q
            };
            state_q <= FireGnh;
          end else if (dset_q && look_q) begin
            look_q <= 1'b0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC, kind: APU_GNH_DESCSET,
              object_id: rec_q.object_id, handle: '0
            };
            state_q <= FireGnh;
          end else if (bindimg_q && look_q && !bindimg_mem_q) begin
            bindimg_mem_q <= 1'b1;
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP, kind: APU_GNH_MEMORY, object_id: '0,
              handle: rec_q.object_id
            };
            state_q <= FireGnh;
          end else if (bindimg_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b1, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_IMAGE,
              object_id: rec_q.object_id, handle: rec_q.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              bimg_q[0] <= APU_VBI_CMD_BINDIMG; bimg_q[1] <= 32'd0;
              bimg_q[2] <= 32'd0; bimg_q[3] <= 32'd0;
              bimg_q[4] <= rec_q.handle; bimg_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (imgreq_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b1,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_IMAGE,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_VMI_SIZE
            };
            if (rec_q.reply) begin
              mimg_q[0] <= APU_VMI_CMD_IMGREQ; mimg_q[1] <= 32'd0;
              mimg_q[2] <= APU_VMI_SIZE; mimg_q[3] <= 32'd0;
              mimg_q[4] <= APU_VMI_ALIGN; mimg_q[5] <= APU_VMI_TYPE_BITS;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (upd_q && look_q && !upd_buf_q) begin
            upd_buf_q <= 1'b1;
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
              handle: rec_q.object_id
            };
            state_q <= FireGnh;
          end else if (upd_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b1, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_DESCSET,
              object_id: rec_q.object_id, handle: rec_q.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              treply_q[0] <= APU_VUD_CMD_UPDATE; treply_q[1] <= 32'd0;
              treply_q[2] <= 32'd0; treply_q[3] <= 32'd0;
              treply_q[4] <= rec_q.handle; treply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (vtx_q && look_q && !vtx_buf_q) begin
            vtx_buf_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: rec_q.object_id};
            state_q <= FireGnh;
          end else if (vtx_q && look_q) begin
            look_q <= 1'b0; vtx_bound_q <= 1'b1;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b1, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_BUFFER,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VVB_CMD_BINDVTX; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (idxb_q && look_q && !idx_buf_q) begin
            idx_buf_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: rec_q.object_id};
            state_q <= FireGnh;
          end else if (idxb_q && look_q) begin
            look_q <= 1'b0; idx_bound_q <= 1'b1;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b1, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_BUFFER,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VIB_CMD_BINDIDX; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (drawi_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b1,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_CMDBUF,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_VDI_INDICES
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VDI_CMD_DRAWIDX; tail_q[1] <= 32'd0;
              tail_q[2] <= APU_VDI_INDICES; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (vp_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b1, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_CMDBUF,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VVP_CMD_SETVP; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (sc_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b1, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_CMDBUF,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VSI_CMD_SETSC; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (bar_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b1, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_CMDBUF,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VPB_CMD_BARRIER; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dfb_q && look_q && !dfb_ret_q) begin
            dfb_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_FBUF, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dfb_q && look_q) begin
            look_q <= 1'b0; fbuf_ok_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b1, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DFB_CMD_DFB; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dvw_q && look_q && !dvw_ret_q) begin
            dvw_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_VIEW, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dvw_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b1, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DVW_CMD_DVW; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dsm_q && look_q && !dsm_ret_q) begin
            dsm_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_SAMPLER, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dsm_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b1, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DSM_CMD_DSM; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (drp_q && look_q && !drp_ret_q) begin
            drp_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_RPASS, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (drp_q && look_q) begin
            look_q <= 1'b0; rp_ok_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b1,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DRP_CMD_DRP; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dbf_q && look_q && !dbf_ret_q) begin
            dbf_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dbf_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b1, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DBF_CMD_DBF; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dim_q && look_q && !dim_ret_q) begin
            dim_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dim_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b1, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DIM_CMD_DIM; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (fme_q && look_q && !fme_ret_q) begin
            fme_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_MEMORY, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (fme_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b1, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_FME_CMD_FME; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dmd_q && look_q && !dmd_ret_q) begin
            dmd_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_MODULE, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dmd_q && look_q) begin
            look_q <= 1'b0; loaded_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b1,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DMD_CMD_DMD; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dpl_q && look_q && !dpl_ret_q) begin
            dpl_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_PIPELINE, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dpl_q && look_q) begin
            look_q <= 1'b0; pipe_bound_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b1, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DPL_CMD_DPL; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dyo_q && look_q && !dyo_ret_q) begin
            dyo_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_PLAYOUT, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dyo_q && look_q) begin
            look_q <= 1'b0; pl_ok_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b1, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DYO_CMD_DYO; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dds_q && look_q && !dds_ret_q) begin
            dds_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_DSLAYOUT, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dds_q && look_q) begin
            look_q <= 1'b0; dsl_ok_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b1, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DDS_CMD_DDS; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dpo_q && look_q && !dpo_ret_q) begin
            dpo_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_POOL, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (dpo_q && look_q) begin
            look_q <= 1'b0; pool_ok_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b1,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DPO_CMD_DPO; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (fds_q && look_q && !fds_ret_q) begin
            fds_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_DESCSET, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (fds_q && look_q) begin
            look_q <= 1'b0; dset_ok_q <= 1'b0; desc_bound_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b1, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_FDS_CMD_FDS; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (rcb_q && look_q) begin
            look_q <= 1'b0; begun_q <= 1'b0; ended_q <= 1'b0; in_rp_q <= 1'b0; pipe_bound_q <= 1'b0; desc_bound_q <= 1'b0; vtx_bound_q <= 1'b0; idx_bound_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b1, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_RCB_CMD_RCB; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (fcb_q && look_q && !fcb_ret_q) begin
            fcb_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_CMDBUF, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (fcb_q && look_q) begin
            look_q <= 1'b0; begun_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b1, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_FCB_CMD_FCB; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (ddv_q && look_q && !ddv_ret_q) begin
            ddv_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_DEVICE, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (ddv_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b1,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DDV_CMD_DDV; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (rcp_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b1, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_RCP_CMD_RCP; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dcp_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b1, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DCP_CMD_DCP; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (din_q && look_q && !din_ret_q) begin
            din_ret_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_RETIRE, kind: APU_GNH_INSTANCE, object_id: '0,
                           handle: rec_q.handle};
            state_q <= FireGnh;
          end else if (din_q && look_q) begin
            look_q <= 1'b0; instanced_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b1,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DIN_CMD_DIN; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (fmt_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b1, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_GFP_FEATURES
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_GFP_CMD_GFP; tail_q[1] <= APU_GFP_FEATURES;
              tail_q[2] <= APU_GFP_FEATURES; tail_q[3] <= APU_GFP_FEATURES;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (ifmt_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b1, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_IFP_MAX_EXTENT
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_IFP_CMD_IFP; tail_q[1] <= APU_IFP_MAX_EXTENT;
              tail_q[2] <= APU_IFP_MAX_EXTENT; tail_q[3] <= 32'd1;
              tail_q[4] <= APU_IFP_MAX_MIP; tail_q[5] <= 32'd1;
              tail_q[6] <= APU_IFP_SAMPLES; tail_q[7] <= APU_VMI_SIZE;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dext_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b1, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_DEX_COUNT
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DEX_CMD_DEX; tail_q[1] <= 32'd0;
              tail_q[2] <= APU_DEX_COUNT; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (rdp_q && look_q) begin
            look_q <= 1'b0; desc_bound_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b1,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_RDP_CMD_RDP; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dwi_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b1, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DWI_CMD_DWI; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (gfs_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b1, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_GFS_CMD_GFS; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (wfe_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b1, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_WFE_CMD_WFE; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (rfe_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b1, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_RFE_CMD_RFE; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dfe_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b1,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DFE_CMD_DFE; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (isl_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b1, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_VMI_SIZE
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_ISL_CMD_ISL; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= APU_VMI_SIZE;
              tail_q[4] <= 32'd0; tail_q[5] <= APU_ISL_ROW;
              tail_q[6] <= APU_VMI_SIZE; tail_q[7] <= APU_VMI_SIZE;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (rag_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b1,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_RAG_GRAN
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_RAG_CMD_RAG; tail_q[1] <= APU_RAG_GRAN;
              tail_q[2] <= APU_RAG_GRAN; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (slw_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b1, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_SLW_CMD_SLW; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (sdb_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b1, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_SDB_CMD_SDB; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (sbc_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b1, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_SBC_CMD_SBC; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (sbb_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b1,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_SBB_CMD_SBB; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (scm_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b1, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_SCM_CMD_SCM; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (swm_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b1, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_SWM_CMD_SWM; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (srf_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b1,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_SRF_CMD_SRF; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (ccb_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vcc_rec.src[31:0]};
            state_q <= FireGnh;
          end else if (ccb_q && look_q && !copy_dst_q) begin
            copy_dst_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vcc_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (ccb_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b1, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_CCB_CMD_CCB; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (cci_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vcy_rec.src[31:0]};
            state_q <= FireGnh;
          end else if (cci_q && look_q && !copy_dst_q) begin
            copy_dst_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vcy_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (cci_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b1, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_CCI_CMD_CCI; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (bli_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vbl_rec.src[31:0]};
            state_q <= FireGnh;
          end else if (bli_q && look_q && !copy_dst_q) begin
            copy_dst_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vbl_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (bli_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b1, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_BLI_CMD_BLI; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (cbi_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vbt_rec.src[31:0]};
            state_q <= FireGnh;
          end else if (cbi_q && look_q && !copy_dst_q) begin
            copy_dst_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vbt_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (cbi_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b1,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_CBI_CMD_CBI; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (cib_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vic_rec.src[31:0]};
            state_q <= FireGnh;
          end else if (cib_q && look_q && !copy_dst_q) begin
            copy_dst_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vic_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (cib_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b1, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_CIB_CMD_CIB; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (ubu_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vub_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (ubu_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b1, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_UBF_CMD_UBF; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (fil_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vfl_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (fil_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b1, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_FIL_CMD_FIL; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (ccl_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vcl_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (ccl_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b1,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_CCL_CMD_CCL; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (cds_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vds_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (cds_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b1, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_CDS_CMD_CDS; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (rsl_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vrs_rec.src[31:0]};
            state_q <= FireGnh;
          end else if (rsl_q && look_q && !copy_dst_q) begin
            copy_dst_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_IMAGE, object_id: '0,
                           handle: vrs_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (rsl_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b1,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_RSI_CMD_RSI; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dsi_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vin_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (dsi_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b1, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DSI_CMD_DSI; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (beginrp_q && look_q) begin
            look_q <= 1'b0; in_rp_q <= 1'b1;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b1, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_CMDBUF,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VRB_CMD_BEGINRP; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (draw_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b1, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_CMDBUF,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_VDW_VERTS
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VDW_CMD_DRAW; tail_q[1] <= 32'd0;
              tail_q[2] <= APU_VDW_VERTS; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (dinr_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vio_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (dinr_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b1, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_DRI_COUNT
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_DRI_CMD_DRI; tail_q[1] <= 32'd0;
              tail_q[2] <= APU_DRI_COUNT; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (didi_q && look_q && !copy_src_q) begin
            copy_src_q <= 1'b1;
            gnh_req_q <= '{op: APU_GNH_LOOKUP, kind: APU_GNH_BUFFER, object_id: '0,
                           handle: vix_rec.dst[31:0]};
            state_q <= FireGnh;
          end else if (didi_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b1, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: APU_IXI_COUNT
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_IXI_CMD_IXI; tail_q[1] <= 32'd0;
              tail_q[2] <= APU_IXI_COUNT; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (cat_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid: 1'b1, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b0,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b1,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: gnh_rec.kind,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_CAT_CMD_CAT; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (endrp_q && look_q) begin
            look_q <= 1'b0; in_rp_q <= 1'b0;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b0,
              create_pool: 1'b0, create_image: 1'b0, bind_image: 1'b0, img_req: 1'b0,
              create_view: 1'b0, create_sampler: 1'b0, create_rpass: 1'b0, create_gpipe: 1'b0,
              create_fbuf: 1'b0, begin_rp: 1'b0, draw_cmd: 1'b0, end_rp: 1'b1,
              bind_vtx: 1'b0, bind_idx: 1'b0, draw_idx: 1'b0,
              set_vp: 1'b0, set_sc: 1'b0, barrier: 1'b0, next_sp: 1'b0,
              dest_fbuf: 1'b0, dest_view: 1'b0, dest_samp: 1'b0, dest_rpass: 1'b0,
              dest_buf: 1'b0, dest_img: 1'b0, free_mem: 1'b0, dest_mod: 1'b0,
              dest_pipe: 1'b0, dest_play: 1'b0, dest_dsl: 1'b0, dest_pool: 1'b0,
              free_dset: 1'b0, reset_cbuf: 1'b0, free_cbuf: 1'b0, dest_dev: 1'b0,
              reset_cpool: 1'b0, dest_cpool: 1'b0, dest_inst: 1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_CMDBUF,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              tail_q[0] <= APU_VRE_CMD_ENDRP; tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd0; tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle; tail_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (bp_q && look_q) begin
            look_q <= 1'b0; pipe_bound_q <= 1'b1;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b1, bind_desc: 1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_PIPELINE,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              hreply_q[0] <= APU_VBP_CMD_BINDPIPE; hreply_q[1] <= 32'd0;
              hreply_q[2] <= 32'd0; hreply_q[3] <= 32'd0;
              hreply_q[4] <= gnh_rec.handle; hreply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (bd_q && look_q) begin
            look_q <= 1'b0; desc_bound_q <= 1'b1;
            rec_q <= '{
              valid: gnh_rec.valid, alloc: 1'b0, begin_cmd: 1'b0, end_cmd: 1'b0,
              create: 1'b0, dispatch: 1'b0, submit: 1'b0, wait_idle: 1'b0,
              get_queue: 1'b0, create_device: 1'b0, create_instance: 1'b0,
              enum_phys: 1'b0, get_qfam: 1'b0, get_feat: 1'b0, get_props: 1'b0,
              get_mem: 1'b0, alloc_mem: 1'b0, create_buffer: 1'b0, bind_buffer: 1'b0,
              map_mem: 1'b0, unmap_mem: 1'b0, buf_req: 1'b0, flush_mem: 1'b0,
              inval_mem: 1'b0, mem_commit: 1'b0, create_dslayout: 1'b0,
              create_playout: 1'b0, create_cpipe: 1'b0, alloc_descset: 1'b0,
              update_desc: 1'b0, bind_pipe: 1'b0, bind_desc: 1'b1,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded: loaded_q, begun: begun_q, reply: rec_q.reply,
              slot: gnh_rec.slot, gen: gnh_rec.gen, kind: APU_GNH_DESCSET,
              object_id: gnh_rec.object_id, handle: gnh_rec.handle,
              begin_flags: rec_q.begin_flags, code_words: rec_q.code_words,
              group_x: rec_q.group_x, group_y: rec_q.group_y, group_z: rec_q.group_z,
              result: 32'd0
            };
            if (rec_q.reply) begin
              greply_q[0] <= APU_VBD_CMD_BINDDESC; greply_q[1] <= 32'd0;
              greply_q[2] <= 32'd0; greply_q[3] <= 32'd0;
              greply_q[4] <= gnh_rec.handle; greply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK}; state_q <= Done;
          end else if (bind_q && look_q && !bind_mem_q) begin
            bind_mem_q <= 1'b1;
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_MEMORY,
              object_id: '0,
              handle: rec_q.object_id
            };
            state_q <= FireGnh;
          end else if (bind_q && look_q) begin
            look_q <= 1'b0;
            bind_ok_q <= 1'b1;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b1,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        APU_GNH_BUFFER,
              object_id:   rec_q.object_id,
              handle:      rec_q.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      32'd0
            };
            if (rec_q.reply) begin
              nreply_q[0] <= APU_VBB_CMD_BIND;
              nreply_q[1] <= 32'd0;
              nreply_q[2] <= 32'd0;
              nreply_q[3] <= 32'd0;
              nreply_q[4] <= rec_q.handle;
              nreply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (map_q && look_q) begin
            look_q <= 1'b0;
            map_ok_q <= 1'b1;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b1,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   rec_q.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      APU_SHM_BASE[31:0]
            };
            if (rec_q.reply) begin
              ureply_q[0] <= APU_VMM_CMD_MAP;
              ureply_q[1] <= 32'd0;
              ureply_q[2] <= APU_SHM_BASE[31:0];
              ureply_q[3] <= APU_SHM_BASE[63:32];
              ureply_q[4] <= 32'd0;
              ureply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (unmap_q && look_q) begin
            look_q <= 1'b0;
            map_ok_q <= 1'b0;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b1,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      32'd0
            };
            if (rec_q.reply) begin
              wreply_q[0] <= APU_VUM_CMD_UNMAP;
              wreply_q[1] <= 32'd0;
              wreply_q[2] <= 32'd0;
              wreply_q[3] <= 32'd0;
              wreply_q[4] <= 32'd0;
              wreply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (bufreq_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b1,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      APU_VBM_SIZE
            };
            if (rec_q.reply) begin
              xreply_q[0] <= APU_VBM_CMD_BUFREQ;
              xreply_q[1] <= 32'd0;
              xreply_q[2] <= APU_VBM_SIZE;
              xreply_q[3] <= 32'd0;
              xreply_q[4] <= APU_VBM_ALIGN;
              xreply_q[5] <= APU_VBM_TYPE_BITS;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (flush_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b1,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      32'd0
            };
            if (rec_q.reply) begin
              yreply_q[0] <= APU_VFM_CMD_FLUSH;
              yreply_q[1] <= 32'd0;
              yreply_q[2] <= 32'd0;
              yreply_q[3] <= 32'd0;
              yreply_q[4] <= 32'd0;
              yreply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (inval_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b1,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      32'd0
            };
            if (rec_q.reply) begin
              zreply_q[0] <= APU_VIM_CMD_INVAL;
              zreply_q[1] <= 32'd0;
              zreply_q[2] <= 32'd0;
              zreply_q[3] <= 32'd0;
              zreply_q[4] <= 32'd0;
              zreply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (memc_q && look_q) begin
            look_q <= 1'b0;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b1,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      APU_VMC_COMMITTED
            };
            if (rec_q.reply) begin
              creply_q[0] <= APU_VMC_CMD_MEMC;
              creply_q[1] <= 32'd0;
              creply_q[2] <= APU_VMC_COMMITTED;
              creply_q[3] <= 32'd0;
              creply_q[4] <= 32'd0;
              creply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (device_q && look_q) begin
            look_q <= 1'b0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_DEVICE,
              object_id: gnh_rec.handle,
              handle: '0
            };
            state_q <= FireGnh;
          end else if (enum_q && look_q) begin
            look_q <= 1'b0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_PHYS,
              object_id: gnh_rec.handle,
              handle: '0
            };
            state_q <= FireGnh;
          end else if (qfam_q && look_q) begin
            look_q <= 1'b0;
            qfam_ok_q <= 1'b1;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b1,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      APU_VQF_FAMILY_COUNT
            };
            if (rec_q.reply) begin
              freply_q[0] <= APU_VQF_CMD_QFAM;
              freply_q[1] <= 32'd0;
              freply_q[2] <= APU_VQF_FAMILY_COUNT;
              freply_q[3] <= 32'd0;
              freply_q[4] <= APU_VQF_QUEUE_FLAGS;
              freply_q[5] <= APU_VQF_QUEUE_COUNT;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (feat_q && look_q) begin
            look_q <= 1'b0;
            feat_ok_q <= 1'b1;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b1,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      APU_VPF_FRAGMENT_STORES
            };
            if (rec_q.reply) begin
              ereply_q[0] <= APU_VPF_CMD_FEAT;
              ereply_q[1] <= 32'd0;
              ereply_q[2] <= APU_VPF_FRAGMENT_STORES;
              ereply_q[3] <= 32'd0;
              ereply_q[4] <= 32'd0;
              ereply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (props_q && look_q) begin
            look_q <= 1'b0;
            props_ok_q <= 1'b1;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b1,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      APU_VPP_MAX_BOUND_DESCRIPTOR_SETS
            };
            if (rec_q.reply) begin
              sreply_q[0] <= APU_VPP_CMD_PROPS;
              sreply_q[1] <= 32'd0;
              sreply_q[2] <= APU_VPP_API_VERSION;
              sreply_q[3] <= 32'd0;
              sreply_q[4] <= APU_VPP_MAX_BOUND_DESCRIPTOR_SETS;
              sreply_q[5] <= 32'd0;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else if (mem_q && look_q) begin
            look_q <= 1'b0;
            mem_ok_q <= 1'b1;
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b0,
              submit:      1'b0,
              wait_idle:   1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b1,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      loaded_q,
              begun:       begun_q,
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      APU_VMP_TYPE_COUNT
            };
            if (rec_q.reply) begin
              mreply_q[0] <= APU_VMP_CMD_MEM;
              mreply_q[1] <= 32'd0;
              mreply_q[2] <= APU_VMP_TYPE_COUNT;
              mreply_q[3] <= APU_VMP_DEVICE_LOCAL;
              mreply_q[4] <= APU_VMP_HOST_VISIBLE;
              mreply_q[5] <= APU_VMP_HEAP_COUNT;
            end
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:       gnh_rec.valid,
              alloc:       alloc_q,
              begin_cmd:   begin_q,
              end_cmd:     end_q,
              create:      create_q,
              dispatch:    disp_q,
              submit:      submit_q,
              wait_idle:  wait_q,
              get_queue:   queue_q,
              create_device: device_q,
              create_instance: instance_q,
              enum_phys:     enum_q,
              get_qfam:      qfam_q,
              get_feat:      feat_q,
              get_props:     props_q,
              get_mem:       mem_q,
              alloc_mem:     vkmem_q,
              create_buffer: buffer_q,
              bind_buffer:   bind_q,
              map_mem:       map_q,
              unmap_mem:     unmap_q,
              buf_req:       bufreq_q,
              flush_mem:     flush_q,
              inval_mem:     inval_q,
              mem_commit:    memc_q,
              create_dslayout: dsl_q,
              create_playout:  pl_q,
              create_cpipe:    cpipe_q,
              alloc_descset:   dset_q,
              update_desc:     upd_q,
              bind_pipe:       bp_q,
              bind_desc:       bd_q,
              create_pool:     pool_q,
              create_image:    img_q,
              bind_image:      bindimg_q,
              img_req:         imgreq_q,
              create_view:     view_q,
              create_sampler:  samp_q,
              create_rpass:    rpass_q,
              create_gpipe:    gpipe_q,
              create_fbuf:     fbuf_q,
              begin_rp:        beginrp_q,
              draw_cmd:        draw_q,
              end_rp:          endrp_q,
              bind_vtx:        vtx_q,
              bind_idx:        idxb_q,
              draw_idx:        drawi_q,
              set_vp:          vp_q,
              set_sc:          sc_q,
              barrier:         bar_q,
              next_sp:         nextsp_q,
              dest_fbuf:       dfb_q,
              dest_view:       dvw_q,
              dest_samp:       dsm_q,
              dest_rpass:      drp_q,
              dest_buf:        dbf_q,
              dest_img:        dim_q,
              free_mem:        fme_q,
              dest_mod:        dmd_q,
              dest_pipe:       dpl_q,
              dest_play:       dyo_q,
              dest_dsl:        dds_q,
              dest_pool:       dpo_q,
              free_dset:       fds_q,
              reset_cbuf:      rcb_q,
              free_cbuf:       fcb_q,
              dest_dev:        ddv_q,
              reset_cpool:     rcp_q,
              dest_cpool:      dcp_q,
              dest_inst:       din_q,
              get_fmt:         fmt_q,
              get_ifmt:        ifmt_q,
              get_dext:        dext_q,
              reset_dpool:     rdp_q,
              get_iext:        iex_q,
              wait_dev:        dwi_q,
              get_isl:         isl_q,
              get_rag:         rag_q,
              set_lw:          slw_q,
              set_bias:        sdb_q,
              set_blend:       sbc_q,
              set_bounds:      sbb_q,
              set_scmp:         scm_q,
              set_swm:          swm_q,
              set_sref:         srf_q,
              copy_buf:         ccb_q,
              copy_img:         cci_q,
              blit_img:         bli_q,
              copy_b2i:         cbi_q,
              copy_i2b:         cib_q,
              update_buf:       ubu_q,
              fill_buf:         fil_q,
              clear_col:        ccl_q,
              draw_indr:        dinr_q,
              draw_iindr:       didi_q,
              clear_ds:         cds_q,
              clear_att:        cat_q,
              disp_indr:        dsi_q,
              resolve_img:      rsl_q,
              get_fence:        gfs_q,
              wait_fence:       wfe_q,
              reset_fence:      rfe_q,
              dest_fence:       dfe_q,
              loaded:      loaded_q,
              begun:       end_q ? 1'b0 : (begun_q || begin_q),
              reply:       rec_q.reply,
              slot:        gnh_rec.slot,
              gen:         gnh_rec.gen,
              kind:        gnh_rec.kind,
              object_id:   gnh_rec.object_id,
              handle:      gnh_rec.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      rec_q.result
            };
            if (alloc_q && rec_q.reply) begin
              cs_q[5'(APU_VAC_REPLY)] <= APU_VAC_CMD_ALLOC;
              cs_q[5'(APU_VAC_REPLY) + 5'd1] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd2] <= 32'd1;
              cs_q[5'(APU_VAC_REPLY) + 5'd3] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd4] <= gnh_rec.handle;
              cs_q[5'(APU_VAC_REPLY) + 5'd5] <= 32'd0;
            end
            if (begin_q) begin
              begun_q <= 1'b1;
              ended_q <= 1'b0;
              begun_handle_q <= gnh_rec.handle;
              begin_flags_q <= rec_q.begin_flags;
            end else if (end_q) begin
              begun_q <= 1'b0;
              ended_q <= 1'b1;
              ended_handle_q <= gnh_rec.handle;
            end else if (submit_q) submitted_q <= 1'b1;
            else if (queue_q) begin
              queued_q <= 1'b1;
              queue_handle_q <= gnh_rec.handle;
              if (rec_q.reply) begin
                qreply0_q <= APU_VGQ_CMD_QUEUE;
                qreply1_q <= gnh_rec.handle;
              end
            end else if (vkmem_q && rec_q.reply) begin
              areply_q[0] <= APU_VAM_CMD_MEMORY;
              areply_q[1] <= 32'd0;
              areply_q[2] <= 32'd1;
              areply_q[3] <= 32'd0;
              areply_q[4] <= gnh_rec.handle;
              areply_q[5] <= 32'd0;
            end else if (buffer_q && rec_q.reply) begin
              breply_q[0] <= APU_VXB_CMD_BUFFER;
              breply_q[1] <= 32'd0;
              breply_q[2] <= 32'd1;
              breply_q[3] <= 32'd0;
              breply_q[4] <= gnh_rec.handle;
              breply_q[5] <= 32'd0;
            end else if (dsl_q) begin
              dsl_ok_q <= 1'b1;
              if (rec_q.reply) begin
                lreply_q[0] <= APU_VDL_CMD_DSLAYOUT;
                lreply_q[1] <= 32'd0;
                lreply_q[2] <= 32'd1;
                lreply_q[3] <= 32'd0;
                lreply_q[4] <= gnh_rec.handle;
                lreply_q[5] <= 32'd0;
              end
            end else if (pl_q) begin
              pl_ok_q <= 1'b1;
              if (rec_q.reply) begin
                kreply_q[0] <= APU_VPL_CMD_PLAYOUT;
                kreply_q[1] <= 32'd0;
                kreply_q[2] <= 32'd1;
                kreply_q[3] <= 32'd0;
                kreply_q[4] <= gnh_rec.handle;
                kreply_q[5] <= 32'd0;
              end
            end else if (cpipe_q && rec_q.reply) begin
              oreply_q[0] <= APU_VCP_CMD_CPIPE;
              oreply_q[1] <= 32'd0;
              oreply_q[2] <= 32'd1;
              oreply_q[3] <= 32'd0;
              oreply_q[4] <= gnh_rec.handle;
              oreply_q[5] <= 32'd0;
            end else if (pool_q) begin
              pool_ok_q <= 1'b1;
              if (rec_q.reply) begin
                rreply_q[0] <= APU_VPO_CMD_POOL;
                rreply_q[1] <= 32'd0;
                rreply_q[2] <= 32'd1;
                rreply_q[3] <= 32'd0;
                rreply_q[4] <= gnh_rec.handle;
                rreply_q[5] <= 32'd0;
              end
            end else if (img_q && rec_q.reply) begin
              ximg_q[0] <= APU_VXI_CMD_IMAGE;
              ximg_q[1] <= 32'd0;
              ximg_q[2] <= 32'd1;
              ximg_q[3] <= 32'd0;
              ximg_q[4] <= gnh_rec.handle;
              ximg_q[5] <= 32'd0;
            end else if (view_q && rec_q.reply) begin
              tail_q[0] <= APU_VXV_CMD_VIEW;
              tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd1;
              tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle;
              tail_q[5] <= 32'd0;
            end else if (samp_q && rec_q.reply) begin
              tail_q[0] <= APU_VSM_CMD_SAMPLER;
              tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd1;
              tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle;
              tail_q[5] <= 32'd0;
            end else if (rpass_q) begin
              rp_ok_q <= 1'b1;
              if (rec_q.reply) begin
                tail_q[0] <= APU_VRP_CMD_RPASS;
                tail_q[1] <= 32'd0;
                tail_q[2] <= 32'd1;
                tail_q[3] <= 32'd0;
                tail_q[4] <= gnh_rec.handle;
                tail_q[5] <= 32'd0;
              end
            end else if (gpipe_q && rec_q.reply) begin
              tail_q[0] <= APU_VGP_CMD_GPIPE;
              tail_q[1] <= 32'd0;
              tail_q[2] <= 32'd1;
              tail_q[3] <= 32'd0;
              tail_q[4] <= gnh_rec.handle;
              tail_q[5] <= 32'd0;
            end else if (fbuf_q) begin
              fbuf_ok_q <= 1'b1;
              if (rec_q.reply) begin
                tail_q[0] <= APU_VFB_CMD_FBUF;
                tail_q[1] <= 32'd0;
                tail_q[2] <= 32'd1;
                tail_q[3] <= 32'd0;
                tail_q[4] <= gnh_rec.handle;
                tail_q[5] <= 32'd0;
              end
            end else if (dset_q) begin
              dset_ok_q <= 1'b1;
              if (rec_q.reply) begin
                jreply_q[0] <= APU_VDA_CMD_DESCSET;
                jreply_q[1] <= 32'd0;
                jreply_q[2] <= 32'd1;
                jreply_q[3] <= 32'd0;
                jreply_q[4] <= gnh_rec.handle;
                jreply_q[5] <= 32'd0;
              end
            end else if (device_q && rec_q.reply) begin
              dreply_q[0] <= APU_VCD_CMD_DEVICE;
              dreply_q[1] <= 32'd0;
              dreply_q[2] <= 32'd1;
              dreply_q[3] <= 32'd0;
              dreply_q[4] <= gnh_rec.handle;
              dreply_q[5] <= 32'd0;
            end else if (instance_q) begin
              instanced_q <= 1'b1;
              if (rec_q.reply) begin
                ireply_q[0] <= APU_VCI_CMD_INSTANCE;
                ireply_q[1] <= 32'd0;
                ireply_q[2] <= 32'd1;
                ireply_q[3] <= 32'd0;
                ireply_q[4] <= gnh_rec.handle;
                ireply_q[5] <= 32'd0;
              end
            end else if (enum_q && rec_q.reply) begin
              preply_q[0] <= APU_VEP_CMD_ENUM;
              preply_q[1] <= 32'd0;
              preply_q[2] <= 32'd1;
              preply_q[3] <= 32'd0;
              preply_q[4] <= gnh_rec.handle;
              preply_q[5] <= 32'd0;
            end
            if (disp_q) state_q <= Kick;
            else if (create_q) state_q <= Load;
            else begin
              cpl_q <= '{status: APU_BRU_OK};
              state_q <= Done;
            end
          end
        end
        Load: begin
          if (load_q + 8'd1 == n_q) state_q <= Commit;
          else load_q <= load_q + 8'd1;
        end
        Commit: begin
          loaded_q <= 1'b1;
          rec_q <= '{
            valid:       rec_q.valid,
            alloc:       1'b0,
            begin_cmd:   1'b0,
            end_cmd:     1'b0,
            create:      1'b1,
            dispatch:    1'b0,
            submit:      1'b0,
            wait_idle:  1'b0,
            get_queue:   1'b0,
            create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt: 1'b0, get_ifmt: 1'b0, get_dext: 1'b0, reset_dpool: 1'b0,
              get_iext: 1'b0, wait_dev: 1'b0, get_isl: 1'b0, get_rag: 1'b0,
              set_lw: 1'b0, set_bias: 1'b0, set_blend: 1'b0, set_bounds: 1'b0,
              set_scmp: 1'b0, set_swm: 1'b0, set_sref: 1'b0,
              copy_buf: 1'b0, copy_img: 1'b0, blit_img: 1'b0, copy_b2i: 1'b0,
              copy_i2b: 1'b0, update_buf: 1'b0, fill_buf: 1'b0, clear_col: 1'b0,
              draw_indr: 1'b0, draw_iindr: 1'b0, clear_ds: 1'b0, clear_att: 1'b0,
              disp_indr: 1'b0, resolve_img: 1'b0,
              get_fence: 1'b0, wait_fence: 1'b0, reset_fence: 1'b0, dest_fence: 1'b0,
            loaded:      1'b1,
            begun:       begun_q,
            reply:       1'b0,
            slot:        rec_q.slot,
            gen:         rec_q.gen,
            kind:        rec_q.kind,
            object_id:   rec_q.object_id,
            handle:      rec_q.handle,
            begin_flags: rec_q.begin_flags,
            code_words:  rec_q.code_words,
            group_x:     rec_q.group_x,
            group_y:     rec_q.group_y,
            group_z:     rec_q.group_z,
            result:      rec_q.result
          };
          cpl_q <= '{status: APU_BRU_OK};
          state_q <= Done;
        end
        Kick: state_q <= WaitEx;
        WaitEx: begin
          if (spv_fault) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_BRU_FAULT};
            state_q <= Done;
          end else if (spv_irq) begin
            result_q <= spv_res;
            rec_q <= '{
              valid:       rec_q.valid,
              alloc:       1'b0,
              begin_cmd:   1'b0,
              end_cmd:     1'b0,
              create:      1'b0,
              dispatch:    1'b1,
              submit:      1'b0,
              wait_idle:  1'b0,
              get_queue:   1'b0,
              create_device: 1'b0,
              create_instance: 1'b0,
              enum_phys:     1'b0,
              get_qfam:      1'b0,
              get_feat:      1'b0,
              get_props:     1'b0,
              get_mem:       1'b0,
              alloc_mem:     1'b0,
              create_buffer: 1'b0,
              bind_buffer:   1'b0,
              map_mem:       1'b0,
              unmap_mem:     1'b0,
              buf_req:       1'b0,
              flush_mem:     1'b0,
              inval_mem:     1'b0,
              mem_commit:    1'b0,
              create_dslayout: 1'b0,
              create_playout:  1'b0,
              create_cpipe:    1'b0,
              alloc_descset:   1'b0,
              update_desc:     1'b0,
              bind_pipe:       1'b0,
              bind_desc:       1'b0,
              create_pool:     1'b0,
              create_image:    1'b0,
              bind_image:      1'b0,
              img_req:         1'b0,
              create_view:     1'b0,
              create_sampler:  1'b0,
              create_rpass:    1'b0,
              create_gpipe:    1'b0,
              create_fbuf:     1'b0,
              begin_rp:        1'b0,
              draw_cmd:        1'b0,
              end_rp:          1'b0,
              bind_vtx:        1'b0,
              bind_idx:        1'b0,
              draw_idx:        1'b0,
              set_vp:          1'b0,
              set_sc:          1'b0,
              barrier:         1'b0,
              next_sp:         1'b0,
              dest_fbuf:       1'b0,
              dest_view:       1'b0,
              dest_samp:       1'b0,
              dest_rpass:      1'b0,
              dest_buf:        1'b0,
              dest_img:        1'b0,
              free_mem:        1'b0,
              dest_mod:        1'b0,
              dest_pipe:       1'b0,
              dest_play:       1'b0,
              dest_dsl:        1'b0,
              dest_pool:       1'b0,
              free_dset:       1'b0,
              reset_cbuf:      1'b0,
              free_cbuf:       1'b0,
              dest_dev:        1'b0,
              reset_cpool:     1'b0,
              dest_cpool:      1'b0,
              dest_inst:       1'b0,
              get_fmt:         1'b0,
              get_ifmt:        1'b0,
              get_dext:        1'b0,
              reset_dpool:     1'b0,
              get_iext:        1'b0,
              wait_dev:        1'b0,
              get_isl:         1'b0,
              get_rag:         1'b0,
              set_lw:          1'b0,
              set_bias:        1'b0,
              set_blend:       1'b0,
              set_bounds:      1'b0,
              set_scmp:         1'b0,
              set_swm:          1'b0,
              set_sref:         1'b0,
              copy_buf:         1'b0,
              copy_img:         1'b0,
              blit_img:         1'b0,
              copy_b2i:         1'b0,
              copy_i2b:         1'b0,
              update_buf:       1'b0,
              fill_buf:         1'b0,
              clear_col:        1'b0,
              draw_indr:        1'b0,
              draw_iindr:       1'b0,
              clear_ds:         1'b0,
              clear_att:        1'b0,
              disp_indr:        1'b0,
              resolve_img:      1'b0,
              get_fence:        1'b0,
              wait_fence:       1'b0,
              reset_fence:      1'b0,
              dest_fence:       1'b0,
              loaded:      1'b1,
              begun:       1'b1,
              reply:       1'b0,
              slot:        rec_q.slot,
              gen:         rec_q.gen,
              kind:        rec_q.kind,
              object_id:   rec_q.object_id,
              handle:      rec_q.handle,
              begin_flags: rec_q.begin_flags,
              code_words:  rec_q.code_words,
              group_x:     rec_q.group_x,
              group_y:     rec_q.group_y,
              group_z:     rec_q.group_z,
              result:      spv_res
            };
            cpl_q <= '{status: APU_BRU_OK};
            state_q <= Done;
          end
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// BeginRun (bru) enable-0 fixture: ALLOC, BEGIN LOOKUP, CREATE, DISPATCH, END LOOKUP.
module g6lc_apu_bru_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_bru_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_bru_cpl_t cpl_o,
  output apu_bru_t bru_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  g6lc_apu_bru #(.Enable(Enable)) i_dut (.*);
endmodule
