from autoconduct.resumer import is_safe_resume

UUID = "01a1a6ba-5a46-77f1-b25a-8a547f7594d1"


def test_rejects_flag_shaped_session_id(tmp_path):
    (tmp_path / "code" / "app").mkdir(parents=True)
    ws = str(tmp_path / "code" / "app")
    assert is_safe_resume(UUID, ws, home=str(tmp_path))
    assert not is_safe_resume("--dangerously-skip-permissions", ws, home=str(tmp_path))


def test_rejects_home_dotdirs_library_and_outside(tmp_path):
    for bad in ["", "relative", str(tmp_path), str(tmp_path / ".ssh"),
                str(tmp_path / "Library" / "LaunchAgents"), "/etc"]:
        assert not is_safe_resume(UUID, bad, home=str(tmp_path)), bad
