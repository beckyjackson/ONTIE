### Workflow
#
# 1. [Edit](./src/scripts/cogs.sh) the Google Sheet
# 2. [Validate](validate) sheet
# 3. Compare `master` branch to current tables:
#     - [predicates](build/diff/predicates.html)
#     - [index](build/diff/index.html)
#     - [external](build/diff/external.html)
#     - [protein](build/diff/protein.html)
#     - [disease](build/diff/disease.html)
#     - [taxon](build/diff/taxon.html)
#     - [other](build/diff/other.html)
# 4. [Update](update) ontology files
# 5. View the results:
#     - [ROBOT report](build/report.html)
#     - [ROBOT diff](build/diff.html)
#       comparing master branch [ontie.owl](https://github.com/IEDB/ONTIE/blob/master/ontie.owl)
#       to this branch [ontie.owl](ontie.owl)
#     - [Tree](build/ontie-tree.html)
#     - [ontie.owl](ontie.owl)

KNODE := java -jar knode.jar
ROBOT := java -jar build/robot.jar --prefix "ONTIE: https://ontology.iedb.org/ontology/ONTIE_"
ROBOT_VALIDATE := java -jar build/robot-validate.jar --prefix "ONTIE: https://ontology.iedb.org/ontology/ONTIE_"
ROBOT_REPORT := java -jar build/robot-report.jar --prefix "ONTIE: https://ontology.iedb.org/ontology/ONTIE_"
COGS := cogs

DATE := $(shell date +%Y-%m-%d)

build resources build/validate build/diff build/master:
	mkdir -p $@

build/robot.jar: | build
	curl -L -o $@ https://build.obolibrary.io/job/ontodev/job/robot/job/error-tables/4/artifact/bin/robot.jar

build/robot-validate.jar: | build
	curl -L -o $@ https://build.obolibrary.io/job/ontodev/job/robot/job/add_validate_operation/lastSuccessfulBuild/artifact/bin/robot.jar

build/robot-report.jar: | build
	curl -L -o $@ https://build.obolibrary.io/job/ontodev/job/robot/job/html-report/lastSuccessfulBuild/artifact/bin/robot.jar

UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
	RDFTAB_URL := https://github.com/ontodev/rdftab.rs/releases/download/v0.1.1/rdftab-x86_64-apple-darwin
else
	RDFTAB_URL := https://github.com/ontodev/rdftab.rs/releases/download/v0.1.1/rdftab-x86_64-unknown-linux-musl
endif

build/rdftab: | build
	curl -L -o $@ $(RDFTAB_URL)
	chmod +x $@

# ROBOT templates from Google sheet

SHEETS := predicates index external protein complex disease taxon other
TABLES := $(foreach S,$(SHEETS),src/ontology/templates/$(S).tsv)

# ONTIE from templates

ontie.owl: $(TABLES) src/ontology/metadata.ttl build/imports.ttl | build/robot.jar
	$(ROBOT) template \
	$(foreach T,$(TABLES),--template $(T)) \
	merge \
	--input src/ontology/metadata.ttl \
	--input build/imports.ttl \
	--include-annotations true \
	annotate \
	--ontology-iri "https://ontology.iebd.org/ontology/$@" \
	--version-iri "https://ontology.iebd.org/ontology/$(DATE)/$@" \
	--output $@

build/report.%: ontie.owl | build/robot-report.jar
	$(ROBOT_REPORT) remove \
	--input $< \
	--base-iri ONTIE \
	--axioms external \
	report \
	--output $@ \
	--standalone true \
	--print 20

build/diff.html: ontie.owl | build/robot.jar
	git show master:ontie.owl > build/ontie.master.owl
	$(ROBOT) diff -l build/ontie.master.owl -r $< -f html -o $@

DIFF_TABLES := $(foreach S,$(SHEETS),build/diff/$(S).html)

build/diff/%.html: src/ontology/templates/%.tsv | build/master build/diff
	git show master:$^ > build/master/$(notdir $<)
	daff build/master/$(notdir $<) $< --output $@

diffs: $(DIFF_TABLES)


# Imports

IMPORTS := doid obi
OWL_IMPORTS := $(foreach I,$(IMPORTS),resources/$(I).owl)
DBS := $(foreach I,$(IMPORTS),resources/$(I).db)
MODULES := $(foreach I,$(IMPORTS),build/$(I)-import.ttl)

$(OWL_IMPORTS): | resources
	curl -Lk -o $@ http://purl.obolibrary.org/obo/$(notdir $@)

resources/%.db: src/scripts/prefixes.sql resources/%.owl | build/rdftab
	rm -rf $@
	sqlite3 $@ < $<
	./build/rdftab $@ < $(word 2,$^)

build/terms.txt: src/ontology/templates/external.tsv
	awk -F '\t' '{print $$1}' $< | tail -n +3 | sed '/NCBITaxon:/d' > $@

ANN_PROPS := IAO:0000112 IAO:0000115 IAO:0000118 IAO:0000119

build/%-import.ttl: src/scripts/mireot.py resources/%.db build/terms.txt
	$(eval ANNS := $(foreach A,$(ANN_PROPS), -a $(A)))
	python3 $< -d $(word 2,$^) -t $(word 3,$^) $(ANNS) -n -o $@

build/imports.ttl: $(MODULES) | build/robot.jar
	$(eval INS := $(foreach M,$(MODULES), --input $(M)))
	$(ROBOT) merge $(INS) --output $@

.PHONY: clean-imports
clean-imports:
	rm -rf $(OWL_IMPORTS)

refresh-imports: clean-imports build/imports.ttl


# Tree Building

build/robot-tree.jar: | build
	curl -L -o $@ https://build.obolibrary.io/job/ontodev/job/robot/job/tree-view/lastSuccessfulBuild/artifact/bin/robot.jar

build/ontie-tree.html: ontie.owl | build/robot-tree.jar
	java -jar build/robot-tree.jar --prefix "ONTIE: https://ontology.iedb.org/ontology/ONTIE_" \
	tree --input $< --tree $@


# Main tasks

.PHONY: update
update:
	make validate build/ontie-tree.html

.PHONY: clean
clean:
	rm -rf build/

.PHONY: test
test: build/report.tsv

.PHONY: all
all: test


# COGS Tasks

# Create a new Google sheet with branch name & share it with provided email

COGS_SHEETS := $(foreach S,$(SHEETS),.cogs/$(S).tsv)

.PHONY: load
load: $(COGS_SHEETS)
	mv .cogs/sheet.tsv sheet.tsv
	sed s/0/3/ sheet.tsv > .cogs/sheet.tsv
	rm sheet.tsv

.cogs/%.tsv: src/ontology/templates/%.tsv | .cogs
	$(COGS) add $<

.PHONY: push
push:
	$(COGS) push

.PHONY: show
show:
	$(COGS) open

# Tasks after editing Google Sheets

.PHONY: validate
validate: update-sheets apply push

.PHONY: update-sheets
update-sheets:
	$(COGS) fetch && $(COGS) pull

INDEX := src/ontology/templates/index.tsv
build/report-problems.tsv: src/scripts/report.py $(TABLES) | build
	rm -f $@ && touch $@
	python3 $< \
	--index $(INDEX) \
	--templates $(filter-out $(INDEX), $(TABLES)) > $@

build/ontie.owl:
	cp ontie.owl $@

build/template-problems.tsv: $(TABLES) | build/robot.jar
	rm -f $@ && touch $@
	$(ROBOT) template \
	$(foreach T,$(TABLES),--template $(T)) \
	--force true \
	--errors $@

# TODO - only do this if there are no template issues?
build/validate-problems.tsv: build/ontie.owl $(TABLES) | build/validate build/robot-validate.jar
	rm -f $@ && touch $@
	$(ROBOT_VALIDATE) validate \
	--input $< \
	$(foreach i,$(TABLES),--table $(i)) \
	--reasoner hermit \
	--skip-row 2 \
	--format txt \
	--errors $@ \
	--no-fail true \
	--output-dir build/validate

.PHONY: apply
apply: build/report-problems.tsv build/template-problems.tsv
	$(COGS) apply $^

