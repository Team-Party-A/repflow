"""Add the food catalogue, immutable versions, meals and analysis jobs."""

from alembic import op

revision = "0003_nutrition"
down_revision = "0002_workouts"
branch_labels = None
depends_on = None


def upgrade():
    op.execute("""
        CREATE TABLE nutrition_foods (
            id uuid PRIMARY KEY, owner_id uuid REFERENCES users(user_id),
            name text NOT NULL, preparation text NOT NULL, name_key text NOT NULL,
            preparation_key text NOT NULL, aliases text[] NOT NULL, alias_keys text[] NOT NULL,
            source text NOT NULL CHECK (source IN ('private','ai_estimate','verified')),
            version integer NOT NULL CHECK (version > 0), source_reference text,
            profile jsonb NOT NULL, merged_into uuid REFERENCES nutrition_foods(id),
            request_key uuid, input_hash text,
            CHECK ((source = 'private') = (owner_id IS NOT NULL)),
            CHECK (source <> 'verified' OR length(trim(source_reference)) > 0 AND source_reference IS NOT NULL),
            UNIQUE (owner_id, request_key)
        )
    """)
    op.execute("""CREATE UNIQUE INDEX nutrition_public_key ON nutrition_foods
        (name_key, preparation_key) WHERE owner_id IS NULL AND merged_into IS NULL""")
    op.execute("""CREATE TABLE nutrition_food_versions (
        food_id uuid REFERENCES nutrition_foods(id), version integer NOT NULL,
        snapshot jsonb NOT NULL, PRIMARY KEY (food_id, version))""")
    op.execute("""CREATE TABLE nutrition_submissions (
        id uuid PRIMARY KEY, food_id uuid NOT NULL, version integer NOT NULL,
        status text NOT NULL CHECK (status IN ('pending','verified','rejected','merged')),
        public_id uuid REFERENCES nutrition_foods(id), UNIQUE(food_id, version),
        FOREIGN KEY(food_id, version) REFERENCES nutrition_food_versions(food_id, version))""")
    op.execute("""CREATE TABLE nutrition_meals (
        id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES users(user_id),
        revision integer NOT NULL CHECK (revision > 0), eaten_at timestamptz,
        input_hash text NOT NULL, deleted boolean NOT NULL)""")
    op.execute("""CREATE INDEX nutrition_day ON nutrition_meals(owner_id, eaten_at, id)
        WHERE NOT deleted""")
    op.execute("""CREATE TABLE nutrition_meal_items (
        meal_id uuid REFERENCES nutrition_meals(id) ON DELETE CASCADE, position integer NOT NULL,
        grams numeric CHECK (grams > 0), snapshot jsonb NOT NULL, PRIMARY KEY(meal_id, position))""")
    op.execute("""CREATE TABLE nutrition_analyses (
        id uuid PRIMARY KEY, owner_id uuid NOT NULL REFERENCES users(user_id), request_key uuid NOT NULL,
        input_hash text NOT NULL, created_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
        status text NOT NULL CHECK (status IN ('queued','processing','ready','failed','expired')),
        failure_code text, items jsonb NOT NULL, metrics jsonb NOT NULL, UNIQUE(owner_id, request_key))""")
    op.execute("CREATE INDEX nutrition_analyses_date ON nutrition_analyses(created_at)")


def downgrade():
    for table in (
        "nutrition_analyses",
        "nutrition_meal_items",
        "nutrition_meals",
        "nutrition_submissions",
        "nutrition_food_versions",
        "nutrition_foods",
    ):
        op.drop_table(table)
