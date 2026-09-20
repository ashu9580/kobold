ALTER TABLE "nethys_bestiary" ALTER COLUMN "elastic_index" SET DATA TYPE bigint USING "elastic_index"::bigint;--> statement-breakpoint
ALTER TABLE "nethys_compendium" ALTER COLUMN "elastic_index" SET DATA TYPE bigint USING "elastic_index"::bigint;
