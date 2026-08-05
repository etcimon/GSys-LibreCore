..
   Copyright (c) 2022 OpenHW Group

   Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

   https://solderpad.org/licenses/

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

   SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

CVA6 Design Document (deprecated)
=================================
Editor: **Florian Zaruba**
`florian@openhwgroup.org <mailto:florian@openhwgroup.org?subject=CVA6%20Design%20Document>`__

.. note::

   This classical Ariane/CVA6 stage-oriented design manual is **deprecated**
   as a full description of the CVA6V-EC worktree. It remains useful historical
   context for the baseline in-order pipeline.

   For current monorepo documentation use:

   * ``docs/website/`` — worktree, build-platform, boards, PDK, **sv-timing**
   * repo-root ``AGENTS.md`` / ``architecture/README.md`` — live RTL map,
     config-gated OoO/SMT/L2, upgrade programs
   * ``docs/design/`` adoc design manuals for config-generated product books

.. toctree::
   :maxdepth: 2
   :caption: Contents:

   intro
   pcgen_stage
   if_stage
   id_stage
   issue_stage
   ex_stage
   MMU
   commit_stage

Indices and tables
------------------

* :ref:`genindex`
* :ref:`modindex`
* :ref:`search`

Documentation
-------------

The documentation is re-generated on pushes to master.
When contributing to the project please consider the [contribution guide](https://github.com/openhwgroup/cva6/blob/master/CONTRIBUTING.md).
