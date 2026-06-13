#####Install and load packages############################################################

library(DESeq2)
library(RColorBrewer)
library(pheatmap)
library(tidyverse)
library(apeglm)

#####Preparing count matrix & metadata#####################################################
files <- list.files(pattern = "*.rawcounts")

# Read and merge all files
counts_list <- lapply(files, function(f) {
  df <- read.table(f, header = FALSE, col.names = c("gene_id", "count"))
  sample_name <- gsub("GSM\\d+_", "", f)
  sample_name <- gsub("\\.rawcounts\\.txt", "", sample_name)
  df[[sample_name]] <- df$count
  df[, c("gene_id", sample_name)]
})

# Merge all by gene_id
counts_matrix <- Reduce(function(x, y) merge(x, y, by = "gene_id", all = FALSE), counts_list)
counts_matrix[is.na(counts_matrix)] <- 0

counts_matrix <- counts_matrix[counts_matrix$gene_id != "" & !is.na(counts_matrix$gene_id), ]
counts_matrix <- counts_matrix[!duplicated(counts_matrix$gene_id), ]

rownames(counts_matrix) <- counts_matrix$gene_id
counts_matrix$gene_id <- NULL

write.csv(counts_matrix, "smoc2_wt_rawcounts.csv")

# Subset to SMOC2 samples only
smoc2_rawcounts <- counts_matrix[, grepl("^SMOC2", colnames(counts_matrix))]

# Rename columns
colnames(smoc2_rawcounts) <- c("smoc2_normal1", "smoc2_normal3", "smoc2_normal4",
                               "smoc2_fibrosis1", "smoc2_fibrosis2", "smoc2_fibrosis3", "smoc2_fibrosis4")

# Save SMOC2-only matrix
write.csv(smoc2_rawcounts, "smoc2_rawcounts.csv")

# Create metadata file
genotype  <- rep("smoc2_oe", 7)
condition <- c("normal", "normal", "normal", "fibrosis", "fibrosis", "fibrosis", "fibrosis")
smoc2_metadata <- data.frame(genotype, condition,
                             row.names = c("smoc2_normal1", "smoc2_normal3", "smoc2_normal4",
                                           "smoc2_fibrosis1", "smoc2_fibrosis2", "smoc2_fibrosis3", "smoc2_fibrosis4"))

# Reorder columns to match metadata
smoc2_rawcounts <- smoc2_rawcounts[, rownames(smoc2_metadata)]

all(colnames(smoc2_rawcounts) == rownames(smoc2_metadata)) 

#####Differential expression analysis######################################################
# Create DESeq2 object
dds_smoc2 <- DESeqDataSetFromMatrix(countData = smoc2_rawcounts,
                                    colData = smoc2_metadata,
                                    design = ~ condition)

dds_smoc2$condition <- relevel(dds_smoc2$condition, ref = "normal")

# Estimate size factors and extract normalized counts
dds_smoc2 <- estimateSizeFactors(dds_smoc2)
smoc2_normalized_counts <- counts(dds_smoc2, normalized = TRUE)

# Variance stabilizing transformation for QC plots
vsd_smoc2 <- vst(dds_smoc2, blind = TRUE)
vsd_mat_smoc2 <- assay(vsd_smoc2)

# Sample correlation heatmap
vsd_cor_smoc2 <- cor(vsd_mat_smoc2)
pheatmap(vsd_cor_smoc2, annotation = select(smoc2_metadata, condition))

# PCA plot
plotPCA(vsd_smoc2, intgroup = "condition")

# Run DESeq2
dds_smoc2 <- DESeq(dds_smoc2)

# Dispersion plot
plotDispEsts(dds_smoc2)

# Extract results
smoc2_res <- results(dds_smoc2,
                     contrast = c("condition", "fibrosis", "normal"),
                     alpha = 0.05,
                     lfcThreshold = 0.32)

# Shrink log2 fold changes
smoc2_res <- lfcShrink(dds_smoc2,
                       coef = "condition_fibrosis_vs_normal",
                       type = "apeglm",
                       res = smoc2_res)

summary(smoc2_res)

smoc2_res_all <- data.frame(smoc2_res)

smoc2_res_sig <- subset(smoc2_res_all, padj < 0.05)

#####Visualisation#########################################################################
# MA plot
plotMA(smoc2_res)

# Generate logical column 
smoc2_res_all <- data.frame(smoc2_res) %>% mutate(threshold = padj < 0.05)

# Volcano plot
ggplot(smoc2_res_all) + 
  geom_point(aes(x = log2FoldChange, y = -log10(padj), color = threshold)) + 
  xlab("log2 fold change") + 
  ylab("-log10 adjusted p-value") + 
  theme(legend.position = "none", 
        plot.title = element_text(size = rel(1.5), hjust = 0.5), 
        axis.title = element_text(size = rel(1.25)))

# Subset normalized counts to significant genes
sig_norm_counts_smoc2 <- smoc2_normalized_counts[rownames(smoc2_res_sig), ]

heat_colors <- brewer.pal(n = 6, name = "PuRd")

# Plot heatmap
pheatmap(sig_norm_counts_smoc2, 
         color = heat_colors, 
         cluster_rows = TRUE, 
         show_rownames = FALSE,
         annotation = select(smoc2_metadata, condition), 
         scale = "row")

# Order DEGs
smoc2_res_sig <- smoc2_res_sig %>%
  rownames_to_column(var = "geneID") %>%
  arrange(padj)

smoc2_res_sig %>%
  select(geneID, padj) %>%
  head()

smoc2_res_sig %>%
  select(geneID) %>%
  write.csv("smoc2_sig_geneIDs.csv", row.names = FALSE)

smoc2_res_sig %>%
  write.csv("smoc2_sig_DEGs_full.csv", row.names = FALSE)

#####Functional & pathway enrichment analysis##############################################

#BiocManager::install(c("clusterProfiler", "org.Mm.eg.db", "enrichplot", "DOSE"))

library(clusterProfiler)
library(org.Mm.eg.db)  
library(enrichplot)

# Convert Ensembl IDs to Entrez IDs
gene_ids <- smoc2_res_sig$geneID

entrez_ids <- bitr(gene_ids,
                   fromType = "ENSEMBL",
                   toType   = "ENTREZID",
                   OrgDb    = org.Mm.eg.db)

# GO Enrichment (Biological Process)
go_bp <- enrichGO(gene         = entrez_ids$ENTREZID,
                  OrgDb        = org.Mm.eg.db,
                  ont          = "BP",       
                  pAdjustMethod = "BH",
                  pvalueCutoff  = 0.05,
                  qvalueCutoff  = 0.05,
                  readable      = TRUE)

# GO Enrichment (Molecular function)
go_mf <- enrichGO(gene         = entrez_ids$ENTREZID,
                  OrgDb        = org.Mm.eg.db,
                  ont          = "MF",       
                  pAdjustMethod = "BH",
                  pvalueCutoff  = 0.05,
                  qvalueCutoff  = 0.05,
                  readable      = TRUE)

# GO Enrichment (Cellular component)
go_cc <- enrichGO(gene         = entrez_ids$ENTREZID,
                  OrgDb        = org.Mm.eg.db,
                  ont          = "CC",      
                  pAdjustMethod = "BH",
                  pvalueCutoff  = 0.05,
                  qvalueCutoff  = 0.05,
                  readable      = TRUE)

# Dotplot
dotplot(go_bp, showCategory = 20, title = "GO Biological process")
dotplot(go_mf, showCategory = 20, title = "GO Molecular function")
dotplot(go_cc, showCategory = 20, title = "GO Cellular component")

# Enrichment map
go_bp_sim <- pairwise_termsim(go_bp)
emapplot(go_bp_sim, showCategory = 20)

go_mf_sim <- pairwise_termsim(go_mf)
emapplot(go_mf_sim, showCategory = 20)

go_cc_sim <- pairwise_termsim(go_cc)
emapplot(go_cc_sim, showCategory = 20)

# KEGG Pathway Enrichment
kegg_res <- enrichKEGG(gene         = entrez_ids$ENTREZID,
                       organism     = "mmu",     # mmu = mouse; hsa = human
                       pAdjustMethod = "BH",
                       pvalueCutoff  = 0.05)

# Dotplot
dotplot(kegg_res, showCategory = 20, title = "KEGG Pathway Enrichment")

# Barplot
barplot(kegg_res, showCategory = 20, title = "KEGG Pathway Enrichment")

#####GSEA##################################################################################
# Convert all genes in smoc2_res_all
smoc2_res_all_named <- smoc2_res_all %>%
  rownames_to_column(var = "geneID")

entrez_all <- bitr(smoc2_res_all_named$geneID,
                   fromType = "ENSEMBL",
                   toType   = "ENTREZID",
                   OrgDb    = org.Mm.eg.db)

# Join and create ranked list by log2FoldChange
ranked_genes <- smoc2_res_all_named %>%
  left_join(entrez_all, by = c("geneID" = "ENSEMBL")) %>%
  filter(!is.na(ENTREZID) & !is.na(log2FoldChange)) %>%
  group_by(ENTREZID) %>%
  slice_max(order_by = abs(log2FoldChange), n = 1) %>%  # keep highest per Entrez ID
  ungroup() %>%
  arrange(desc(log2FoldChange)) %>%
  { setNames(.$log2FoldChange, .$ENTREZID) }

# GSEA on KEGG
gsea_kegg <- gseKEGG(geneList     = ranked_genes,
                     organism     = "mmu",
                     pAdjustMethod = "BH",
                     pvalueCutoff  = 0.05)

# Dotplot
dotplot(gsea_kegg, showCategory = 20, split = ".sign") +
  facet_grid(. ~ .sign)

# Ridge plot 
ridgeplot(gsea_kegg, showCategory = 10)

# GSEA plot for a single pathway
gseaplot2(gsea_kegg, geneSetID = 1, title = gsea_kegg$Description[1])

###############################################################################################################################################################################################
# N.B.: This is an updated GSEA KEGG to improve visibility:
library(ggplot2)

gsea_df <- as.data.frame(gsea_kegg)

gsea_df$direction <- ifelse(gsea_df$NES > 0, "Activated", "Suppressed")

# Take top 15 per direction
gsea_top <- gsea_df %>%
  group_by(direction) %>%
  slice_min(order_by = p.adjust, n = 15) %>%
  ungroup() %>%
  mutate(Description = reorder(Description, NES))  # order by NES score

# Plot
ggplot(gsea_top, aes(x = NES, y = Description, size = setSize, color = p.adjust)) +
  geom_point() +
  facet_wrap(~ direction, scales = "free_y") +
  scale_color_gradient(low = "red", high = "blue") +
  labs(x = "Normalized Enrichment Score (NES)",
       y = NULL,
       color = "Adjusted p-value",
       size = "Gene set size",
       title = "GSEA KEGG Pathway Enrichment") +
  theme_bw() +
  theme(axis.text.y = element_text(size = 9),
        strip.text = element_text(size = 11, face = "bold"),
        plot.title = element_text(hjust = 0.5))
