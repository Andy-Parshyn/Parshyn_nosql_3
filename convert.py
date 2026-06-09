"""convert.py — конвертація MovieLens 1M з .dat у .csv.

Вхідні файли MovieLens використовують роздільник '::' і кодування Latin-1.
Цей скрипт читає їх із розпакованої папки ml-1m/ і записує CSV (роздільник ',',
кодування UTF-8) у папку import/, звідки Neo4j завантажує дані через LOAD CSV.

Використання (один раз перед завантаженням):
    unzip -o ml-1m.zip
    python3 convert.py

Чому csv.writer, а не ручне з'єднання через кому: назви фільмів містять коми
(напр. "American President, The (1995)"), а жанри — символ '|'. csv.writer
автоматично екранує такі поля лапками, і LOAD CSV коректно їх читає.
"""
import csv
import os

SRC = "ml-1m"
DST = "import"
os.makedirs(DST, exist_ok=True)


def convert(src_name, dst_name, header, ncols=None):
    src_path = os.path.join(SRC, src_name)
    dst_path = os.path.join(DST, dst_name)
    rows = 0
    with open(src_path, encoding="latin-1") as f_in, \
            open(dst_path, "w", newline="", encoding="utf-8") as f_out:
        writer = csv.writer(f_out)
        writer.writerow(header)
        for line in f_in:
            parts = line.rstrip("\n").split("::")
            if ncols is not None:
                parts = parts[:ncols]
            writer.writerow(parts)
            rows += 1
    print(f"{dst_name}: {rows} рядків")


# movies.dat:  MovieID::Title::Genres
convert("movies.dat", "movies.csv", ["movieId", "title", "genres"])

# ratings.dat: UserID::MovieID::Rating::Timestamp
convert("ratings.dat", "ratings.csv", ["userId", "movieId", "rating", "timestamp"])

# users.dat:   UserID::Gender::Age::Occupation::Zip-code  (zip не потрібен -> ncols=4)
convert("users.dat", "users.csv", ["userId", "gender", "age", "occupation"], ncols=4)

print("Готово. CSV-файли записано у папку import/")
