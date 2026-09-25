# Evaluation harness
#
# Drop contributor-provided, CC-licensed images under `images/` and a labels JSON:
#
# [
#   {"file": "parking1.jpg", "labels": ["utility_junk", "parking"]},
#   {"file": "blink1.jpg", "labels": ["social_miss", "blink"]},
#   {"file": "dog_best.jpg", "labels": ["keep"], "cluster": "dog1", "is_best": true}
# ]
#
# Then:
#   1. Run the iOS analyzer (or cleaner-cli fuse on dumped features)
#   2. `python eval/score_report.py labels.json predictions.json`
#
# Precision / recall are reported per category. Gate regressions in CI once a
# stable public set exists.

categories:
  - utility_junk
  - social_miss
  - near_duplicate
  - pocket_shot
  - screenshot
