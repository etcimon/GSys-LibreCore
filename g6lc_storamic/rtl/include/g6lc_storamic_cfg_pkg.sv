// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

package g6lc_storamic_cfg_pkg;
  localparam int unsigned ContractVersion = 4;
  localparam int unsigned MaxSupportedSticks = 8;
  localparam logic [31:0] ImplementedMediaCaps = 32'b0;

  typedef enum logic [1:0] {
    ProfileOff = 2'b00, ProfileRefuse = 2'b01, ProfileModel = 2'b10,
    ProfileMapped = 2'b11
  } profile_t;

  typedef struct packed {
    bit Enable;
    profile_t Profile;
    int unsigned MaxSticks;
    logic [31:0] RequestedMediaCaps;
    logic [63:0] ModelBase;
    logic [63:0] ModelBytes;
  } storamic_cfg_t;

  localparam storamic_cfg_t StoramicOff = '{
    Enable: 1'b0, Profile: ProfileOff, MaxSticks: 1,
    RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0
  };
  localparam storamic_cfg_t StoramicSkeleton = '{
    Enable: 1'b1, Profile: ProfileRefuse, MaxSticks: 1,
    RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0
  };
  localparam storamic_cfg_t StoramicModel = '{
    Enable: 1'b1, Profile: ProfileModel, MaxSticks: 1,
    RequestedMediaCaps: '0, ModelBase: 64'h8000_0000, ModelBytes: 64'd65536
  };
  localparam storamic_cfg_t StoramicMapped = '{
    Enable: 1'b1, Profile: ProfileMapped, MaxSticks: 1,
    RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0
  };

  function automatic bit cfg_legal(storamic_cfg_t cfg);
    logic [64:0] model_end;
    bit common_legal;
    model_end = {1'b0, cfg.ModelBase} + {1'b0, cfg.ModelBytes};
    common_legal = cfg.MaxSticks >= 1 && cfg.MaxSticks <= MaxSupportedSticks &&
                   (cfg.RequestedMediaCaps & ~ImplementedMediaCaps) == 0;
    if (!common_legal) return 1'b0;
    case (cfg.Profile)
      ProfileOff: return !cfg.Enable && cfg.ModelBase == 0 && cfg.ModelBytes == 0;
      ProfileRefuse: return cfg.Enable && cfg.ModelBase == 0 && cfg.ModelBytes == 0;
      ProfileModel: return cfg.Enable && cfg.MaxSticks == 1 && cfg.ModelBytes != 0 &&
          model_end <= 65'h1_0000_0000_0000_0000;
      ProfileMapped: return cfg.Enable && cfg.ModelBase == 0 && cfg.ModelBytes == 0;
      default: return 1'b0;
    endcase
  endfunction

  function automatic bit backend_legal(bit enable, bit direct_backend_selected);
    return !(enable && direct_backend_selected);
  endfunction
endpackage
