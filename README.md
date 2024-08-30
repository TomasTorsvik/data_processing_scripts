# data_processing_scripts
Miscellaneous pre- and post-processing scripts for NorESM

- Plotting: Scripts for creating plots
    - mg_budget_plot.py: Script for plotting the the tendency terms that contribute to the total tendencies of the cloud microphysics scheme by Morrison and Gettelman in NorESM2/CAM6
- PostProc: Scripts for post processing model output
    - rcat_noresm.sh: Concatenate and compress NorESM model output
- PreProc: Scripts for preparing model input datasets
- Utilities: Miscellaneous scripts and programs
    - buildCPRNC_NIRD.sh: File to build the cprnc tool needed by rcat_noresm.sh
    - test_rcat_noresm.sh: Unit tests for rcat_noresm.sh
