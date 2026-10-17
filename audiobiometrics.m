function audio_biometrics()

    P.Fs = 16000;   P.frameMs = 25;   P.stepMs = 10;   P.alpha = 0.97;
    P.nFilt = 26;   P.nCoef = 13;     P.NFFT = 512;
    P.maxSec  = 12;
    P.denoise = true;
    P.rasta   = false;
    P.zThr    = 1.0;
    P.fbank   = melFilterBank(P.nFilt, P.NFFT, P.Fs);
    P.dctMat  = dctMatrix(P.nFilt, P.nCoef);
    Fs = P.Fs;

    enr = {};  enrNames = {};  enrSig = {};  model = [];
    testSig = [];  testName = '';
    rec = [];  tmr = [];  recMode = '';  t0 = [];

    fig = figure('Name', 'Audio Biometrics', 'NumberTitle', 'off', ...
        'MenuBar', 'none', 'ToolBar', 'none', 'Position', [150 30 960 720], ...
        'CloseRequestFcn', @onClose);

    axWave = axes('Parent', fig, 'Units', 'pixels', 'Position', [60 520 840 165]);
    hLine = plot(axWave, 0, 0, 'b'); grid(axWave, 'on');
    ylim(axWave, [-1 1]); xlabel(axWave, 'Time (s)'); ylabel(axWave, 'Amplitude');
    title(axWave, 'Waveform (shows live while recording)');

    btnRecEnr  = mkBtn('Record Enrollment', [60  460 195 42], @(~,~) startRec('enroll'));
    btnRecTest = mkBtn('Record Test',       [270 460 195 42], @(~,~) startRec('test'));
    btnStop    = mkBtn('STOP',              [480 460 195 42], @(~,~) stopRec());
    set(btnStop, 'Enable', 'off', 'ForegroundColor', [0.8 0 0], 'FontWeight', 'bold');
    btnReset   = mkBtn('Reset All',         [690 460 210 42], @(~,~) resetAll());

    btnLoadEnr  = mkBtn('Load Enrollment File(s)', [60  410 195 38], @(~,~) loadEnroll());
    btnLoadTest = mkBtn('Load Test File',          [270 410 195 38], @(~,~) loadTest());
    chkDen = uicontrol(fig, 'Style', 'checkbox', 'String', 'Noise reduction', 'Value', 1, ...
        'FontSize', 11, 'Position', [490 415 190 28], 'Callback', @(~,~) onOpt());
    chkRasta = uicontrol(fig, 'Style', 'checkbox', 'String', 'RASTA filter', 'Value', 0, ...
        'FontSize', 11, 'Position', [700 415 190 28], 'Callback', @(~,~) onOpt());

    txtEnr  = mkTxt([60 325 840 24], 'Enrollment: none yet (record / load 2 to 5 samples of the SAME phrase)');
    txtTest = mkTxt([60 300 840 24], 'Test voice: not provided yet');
    txtCal  = mkTxt([60 275 840 24], 'Calibration: automatic, from your enrollment samples');

    btnVerify = mkBtn('VERIFY', [60 205 840 55], @(~,~) verify());
    set(btnVerify, 'FontSize', 15, 'FontWeight', 'bold');

    txtResult = uicontrol(fig, 'Style', 'text', 'FontSize', 18, 'FontWeight', 'bold', ...
        'Position', [60 135 840 60], 'String', 'Result will appear here', ...
        'BackgroundColor', [0.94 0.94 0.94]);

    uicontrol(fig, 'Style', 'text', 'FontSize', 10, 'HorizontalAlignment', 'left', ...
        'Position', [60 10 840 115], 'String', sprintf([ ...
        'TIPS:  same short phrase every time (3 to 5 s), same microphone, quiet room.  Enroll 3 to 5 samples.\n' ...
        'Noise reduction / RASTA checkboxes switch those DSP blocks on or off (enrollment is re-analysed).']));

    function b = mkBtn(label, pos, cb)
        b = uicontrol(fig, 'Style', 'pushbutton', 'String', label, ...
            'FontSize', 11, 'Position', pos, 'Callback', cb);
    end

    function t = mkTxt(pos, str)
        t = uicontrol(fig, 'Style', 'text', 'FontSize', 11, ...
            'HorizontalAlignment', 'left', 'Position', pos, 'String', str);
    end

    function setIdle(isIdle)
        s = 'off'; if isIdle, s = 'on'; end
        set([btnRecEnr btnRecTest btnLoadEnr btnLoadTest btnVerify btnReset ...
             chkDen chkRasta], 'Enable', s);
        if isIdle, set(btnStop, 'Enable', 'off'); else, set(btnStop, 'Enable', 'on'); end
    end

    function startRec(m)
        recMode = m;
        try
            rec = audiorecorder(Fs, 16, 1);
            record(rec);
        catch ME
            errordlg(['Cannot access the microphone: ' ME.message ...
                '  Use the Load buttons instead.'], 'Microphone error');
            return;
        end
        t0 = tic;  setIdle(false);
        set(hLine, 'Color', [0.85 0 0]);
        tmr = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.15, ...
                    'TimerFcn', @(~,~) updateLive());
        start(tmr);
    end

    function updateLive()
        if isempty(rec) || ~isvalid(fig), return; end
        x = getaudiodata(rec);
        if isempty(x), return; end
        n = numel(x);  w = min(n, 5*Fs);  seg = x(end-w+1:end);
        set(hLine, 'XData', ((n-w):(n-1))/Fs, 'YData', seg);
        xlim(axWave, [(n-w)/Fs, max((n-w)/Fs + 5, n/Fs)]);
        m = max(0.05, 1.1*max(abs(seg)));  ylim(axWave, [-m m]);
        title(axWave, sprintf('RECORDING (%s) ...  %.1f s     click STOP when finished', ...
              recMode, toc(t0)), 'Color', [0.85 0 0]);
        drawnow limitrate;
    end

    function stopRec()
        if ~isempty(tmr), stop(tmr); delete(tmr); tmr = []; end
        stop(rec);
        x = getaudiodata(rec);
        setIdle(true);
        if numel(x) < 0.5*Fs
            warndlg('Recording too short. Record at least 1 second.'); return;
        end
        if strcmp(recMode, 'enroll')
            addEnroll(x, sprintf('rec#%d', numel(enr)+1));
        else
            setTest(x, 'recorded');
        end
    end

    function filt = audioFilter()
        filt = {'*.wav;*.mp3;*.m4a;*.mp4;*.aac;*.flac;*.ogg;*.opus;*.wma;*.amr;*.3gp;*.webm', ...
                'All audio files'; '*.*', 'All files'};
    end

    function loadEnroll()
        [f, p] = uigetfile(audioFilter(), 'Select enrollment file(s) (multi-select allowed)', 'MultiSelect', 'on');
        if isequal(f, 0), return; end
        if ischar(f), f = {f}; end
        for q = 1:numel(f)
            try
                addEnroll(loadAudio(fullfile(p, f{q}), Fs), f{q});
            catch ME
                errordlg(ME.message, ['Could not read ' f{q}]);
            end
        end
    end

    function loadTest()
        [f, p] = uigetfile(audioFilter(), 'Select the TEST voice');
        if isequal(f, 0), return; end
        try
            setTest(loadAudio(fullfile(p, f), Fs), f);
        catch ME
            errordlg(ME.message, 'Could not read file');
        end
    end

    function showWave(x, ttl, col)
        x = x(:);  dur = numel(x)/Fs;
        set(hLine, 'XData', (0:numel(x)-1)/Fs, 'YData', x, 'Color', col);
        xlim(axWave, [0 max(dur, 1)]);
        m = max(0.05, 1.1*max(abs(x)));  ylim(axWave, [-m m]);
        title(axWave, ttl, 'Color', col*0.8);
    end

    function addEnroll(x, name)
        try
            set(txtEnr, 'String', 'Analysing enrollment sample ...'); drawnow;
            A = analyzeVoice(x, P);
        catch ME
            errordlg(ME.message, 'Enrollment error'); refreshStatus(); return;
        end
        enr{end+1} = A;  enrNames{end+1} = name;  enrSig{end+1} = x(:);
        showWave(x, sprintf('Enrollment sample "%s" captured (%.1f s)', name, numel(x)/Fs), [0 0.55 0]);
        refreshModel();  refreshStatus();
    end

    function setTest(x, name)
        testSig = x(:);  testName = name;
        showWave(testSig, sprintf('Test voice captured (%.1f s)', numel(testSig)/Fs), [0 0.4 0.8]);
        set(txtTest, 'String', sprintf('Test voice:  %s  (%.1f s)  OK', name, numel(testSig)/Fs));
    end

    function onOpt()
        P.denoise = logical(get(chkDen, 'Value'));
        P.rasta   = logical(get(chkRasta, 'Value'));
        if ~isempty(enrSig)
            set(txtEnr, 'String', 'Re-analysing enrollment with new settings ...'); drawnow;
            for i = 1:numel(enrSig)
                try, enr{i} = analyzeVoice(enrSig{i}, P); catch, end
            end
            refreshModel();  refreshStatus();
        end
    end

    function resetAll()
        enr = {};  enrNames = {};  enrSig = {};  model = [];  testSig = [];
        set(hLine, 'XData', 0, 'YData', 0, 'Color', 'b');
        title(axWave, 'Waveform (shows live while recording)', 'Color', 'k');
        set(txtTest, 'String', 'Test voice: not provided yet');
        set(txtResult, 'String', 'Result will appear here', 'ForegroundColor', 'k', ...
            'BackgroundColor', [0.94 0.94 0.94]);
        refreshStatus();
    end

    function refreshModel()
        if numel(enr) >= 2
            set(txtCal, 'String', 'Calibrating threshold from enrollment (DTW between samples) ...'); drawnow;
            model = buildModel(enr, P);
        else
            model = [];
        end
    end

    function refreshStatus()
        n = numel(enr);
        if n == 0
            set(txtEnr, 'String', 'Enrollment: none yet (record / load 2 to 5 samples of the SAME phrase)');
            set(txtCal, 'String', 'Calibration: automatic, from your enrollment samples');
            return;
        end
        set(txtEnr, 'String', sprintf('Enrollment: %d sample(s)  [%s]', n, strjoin(enrNames, ', ')));
        if n < 2
            set(txtCal, 'String', 'Add at least ONE more enrollment sample to calibrate the system.');
        else
            if model.warn
                set(txtCal, 'ForegroundColor', [0.8 0 0], 'String', ...
                    'WARNING: enrollment samples differ a lot. Re-record them with the SAME phrase and same mic.');
            else
                set(txtCal, 'ForegroundColor', 'k', 'String', sprintf(['Auto-calibrated (%d pair(s)).  ' ...
                    'Accept if fused z <= %.1f and DTW z <= %.1f   |   NR=%s  RASTA=%s'], size(model.pairD, 1), ...
                    P.zThr, 2*P.zThr, ternary(P.denoise, 'on', 'off'), ternary(P.rasta, 'on', 'off')));
            end
        end
    end

    function verify()
        if numel(enr) < 2 || isempty(model)
            warndlg('Provide at least 2 enrollment samples first.'); return;
        end
        if isempty(testSig)
            warndlg('Provide a test voice first.'); return;
        end
        set(txtResult, 'String', 'Analysing ...', 'ForegroundColor', 'k'); drawnow;
        try
            A  = analyzeVoice(testSig, P);
            sc = scoreTest(A, model, enr);
        catch ME
            errordlg(ME.message, 'Processing error'); return;
        end
        ok   = isMatch(sc, P);
        conf = 100 / (1 + exp(2.5*(sc.fused - P.zThr)));
        if ok
            set(txtResult, 'ForegroundColor', [0 0.5 0], 'String', ...
                sprintf('MATCH  -  same speaker   (fused z = %.2f, DTW z = %.2f)', sc.fused, sc.z(1)));
        else
            set(txtResult, 'ForegroundColor', [0.8 0 0], 'String', ...
                sprintf('NO MATCH  -  different speaker   (fused z = %.2f, DTW z = %.2f)', sc.fused, sc.z(1)));
        end

        names = {'DTW-MFCC', 'Formants', 'Voice quality', 'Spectral'};
        fprintf('\n================ VERIFICATION REPORT ================\n');
        fprintf('Enrollment samples : %d\n', numel(enr));
        for q = 1:4
            fprintf('  %-14s distance %.3f   z-score %+.2f   weight %.2f\n', ...
                    names{q}, sc.dm(q), sc.z(q), model.w(q));
        end
        fprintf('Formants test (Hz) : F1 %.0f  F2 %.0f  F3 %.0f\n', A.form(1), A.form(2), A.form(3));
        fprintf('Pitch / jitter / shimmer : %.1f Hz / %.3f / %.3f\n', A.voice(1), A.voice(2), A.voice(3));
        fprintf('FUSED z-score      : %.3f   threshold %.1f   ->  %s\n', sc.fused, P.zThr, ternary(ok, 'MATCH', 'NO MATCH'));
        fprintf('Confidence (heuristic) : %.1f %%\n', conf);
        fprintf('=====================================================\n');

        showDashboard(A, sc, ok, conf);
    end

    function showDashboard(A, sc, ok, conf)
        f2 = figure(901); clf(f2);
        set(f2, 'Name', 'Verification Dashboard', 'NumberTitle', 'off', 'Position', [40 30 1380 820]);
        colormap(f2, 'jet');
        t = (0:numel(A.x)-1)/Fs;

        subplot(3,3,1);
        plot(t, A.x, 'b'); hold on; stairs(A.tf, double(A.vad)*0.9, 'r', 'LineWidth', 1.2);
        grid on; xlabel('Time (s)'); ylabel('Amplitude');
        title('1. Denoised waveform + speech detection (red)');

        subplot(3,3,2);
        imagesc(A.tf, A.freqs, A.Sdb); axis xy; hold on;
        mx = max(A.Sdb(:)); caxis([mx-70 mx]);
        plot(A.tf, A.formTrack(:,1), 'w.', 'MarkerSize', 6);
        plot(A.tf, A.formTrack(:,2), 'm.', 'MarkerSize', 6);
        plot(A.tf, A.formTrack(:,3), 'y.', 'MarkerSize', 6);
        ylim([0 5500]); xlabel('Time (s)'); ylabel('Frequency (Hz)');
        title('2. Spectrogram + LPC formants F1(w) F2(m) F3(y)');

        subplot(3,3,3);
        plot(A.tf, A.f0track, 'b.'); hold on; grid on;
        v = cellfun(@(e) e.voice(1), enr);  f0e = median(v(~isnan(v)));
        if ~isnan(f0e), plot([A.tf(1) A.tf(end)], [f0e f0e], 'r--', 'LineWidth', 1.5); end
        ylim([50 450]); xlabel('Time (s)'); ylabel('F0 (Hz)');
        title(sprintf('3. Pitch (autocorr.): test %.0f Hz | enroll %.0f Hz', A.voice(1), f0e));

        subplot(3,3,4);
        imagesc(A.M'); axis xy; colorbar;
        xlabel('Speech frame'); ylabel('MFCC c1..c12');
        title('4. MFCC heat-map (c1..c12)');

        subplot(3,3,5);
        [~, Dm, path] = dtwDist(A.F, enr{sc.best}.F);
        imagesc(Dm); axis xy; hold on;
        plot(path(:,2), path(:,1), 'w', 'LineWidth', 2);
        xlabel(sprintf('enrollment "%s" frame (/2)', enrNames{sc.best})); ylabel('test frame (/2)');
        title('5. DTW cost matrix + optimal alignment path');

        subplot(3,3,6);
        z = sc.z;  z(isnan(z)) = 0;
        bar(1:4, z, 'FaceColor', [0.2 0.5 0.9]); hold on;
        bar(5, sc.fused, 'FaceColor', ternaryC(ok));
        plot([0 6], [P.zThr P.zThr], 'k--', 'LineWidth', 2); grid on; xlim([0 6]);
        set(gca, 'XTick', 1:5, 'XTickLabel', {'DTW', 'Form.', 'Voice', 'Spec.', 'FUSED'});
        ylabel('z-score (lower = more similar)');
        title('6. Per-feature z-scores | dashed = threshold');

        subplot(3,3,7);
        L = mean(cell2mat(cellfun(@(e) e.ltas, enr, 'UniformOutput', false)), 2);
        plot(A.freqs, L, 'b', 'LineWidth', 1.5); hold on;
        plot(A.freqs, A.ltas, 'r', 'LineWidth', 1.5); grid on;
        xlabel('Frequency (Hz)'); ylabel('dB'); legend('Enrollment', 'Test');
        title('7. Long-term average spectrum');

        subplot(3,3,8);
        Fe = nan(numel(enr), 3);
        for i = 1:numel(enr), Fe(i,:) = enr{i}.form(1:3); end
        bar([mean(Fe, 1, 'omitnan'); A.form(1:3)]'); grid on;
        set(gca, 'XTickLabel', {'F1', 'F2', 'F3'}); ylabel('Hz'); legend('Enrollment', 'Test');
        title('8. Vocal-tract resonances (formants)');

        subplot(3,3,9);
        cla; axis([0 1 0 1]); axis off;
        rectangle('Position', [0 0 1 1], 'FaceColor', ternaryC(ok), 'EdgeColor', 'none');
        if ok, vtxt = 'MATCH'; else, vtxt = 'NO MATCH'; end
        text(0.5, 0.82, vtxt, 'Color', 'w', 'FontSize', 20, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
        text(0.5, 0.62, sprintf('Fused z = %.2f   (threshold %.1f)', sc.fused, P.zThr), 'Color', 'w', 'FontSize', 13, 'HorizontalAlignment', 'center');
        text(0.5, 0.46, sprintf('Confidence (heuristic): %.0f %%', conf), 'Color', 'w', 'FontSize', 13, 'HorizontalAlignment', 'center');
        text(0.5, 0.30, sprintf('z: DTW %.1f | Form %.1f | Voice %.1f | Spec %.1f', z), 'Color', 'w', 'FontSize', 10, 'HorizontalAlignment', 'center');
        text(0.5, 0.14, sprintf('jitter %.3f  shimmer %.3f  HNR %.1f dB', A.voice(2), A.voice(3), A.voice(4)-20), 'Color', 'w', 'FontSize', 10, 'HorizontalAlignment', 'center');
    end

    function onClose(~, ~)
        try
            if ~isempty(tmr), stop(tmr); delete(tmr); end
            if ~isempty(rec), stop(rec); end
        catch
        end
        delete(fig);
    end
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end

function ok = isMatch(sc, P)
    ok = sc.fused <= P.zThr && sc.z(1) <= 2 * P.zThr;
end

function c = ternaryC(ok)
    if ok, c = [0.10 0.60 0.20]; else, c = [0.78 0.12 0.12]; end
end

function A = analyzeVoice(x, P)
    x = x(:);
    x = x(1 : min(numel(x), round(P.maxSec * P.Fs)));
    x = x - mean(x);
    if max(abs(x)) < 1e-4
        error('The recording is silent. Check microphone / file.');
    end
    x = x / (max(abs(x)) + eps);
    if P.denoise
        x = spectralSubtract(x, P.Fs);
        x = x / (max(abs(x)) + eps);
    end
    y = [x(1); x(2:end) - P.alpha * x(1:end-1)];

    frameLen = round(P.Fs * P.frameMs / 1000);
    stepLen  = round(P.Fs * P.stepMs  / 1000);
    nF = 1 + floor((numel(y) - frameLen) / stepLen);
    if nF < 30, error('Recording too short (need about 0.5 s or more).'); end

    idx = (1:frameLen)' + (0:nF-1) * stepLen;
    w   = 0.54 - 0.46 * cos(2*pi*(0:frameLen-1)' / (frameLen-1));
    Yw  = y(idx) .* w;

    X  = fft(Yw, P.NFFT);
    Pw = abs(X(1:P.NFFT/2+1, :)).^2;
    E  = max(P.fbank * Pw, eps);
    LE = log(E);
    if P.rasta
        LE = filter(0.1*[2 1 0 -1 -2], [1 -0.98], LE, [], 2);
    end
    C = P.dctMat * LE;

    eDB = 10*log10(sum(Yw.^2, 1)' + eps);
    s = sort(eDB);
    noiseFloor = s(max(1, round(0.1*nF)));
    hi         = s(max(1, round(0.9*nF)));
    vad = eDB > noiseFloor + 0.3*(hi - noiseFloor);
    vad = movmean(double(vad), 7) > 0.5;
    if sum(vad) < 30, vad = eDB >= median(eDB); end
    if sum(vad) < 30, error('Not enough speech detected.'); end

    M = C(2:end, vad)';
    A.F = [M deltaCalc(M, 2)];
    A.M = M;

    A.x = x;  A.vad = vad;
    A.tf = ((0:nF-1) * stepLen + frameLen/2) / P.Fs;
    A.freqs = (0:P.NFFT/2) * P.Fs / P.NFFT;
    A.Sdb = 10*log10(Pw + eps);
    A.ltas = mean(A.Sdb(:, vad), 2);

    A.formTrack = formantTrack(Yw, vad, P);
    okF = all(~isnan(A.formTrack), 2);
    if sum(okF) >= 5
        FT = A.formTrack(okF, :);
        A.form = [median(FT, 1), std(FT, 0, 1)];
    else
        A.form = nan(1, 6);
    end

    [A.f0track, pk, amp, per] = pitchTrack(x, P, nF, stepLen, vad);
    voiced = ~isnan(A.f0track);
    if sum(voiced) >= 5
        f0med = median(A.f0track(voiced));
        dT = abs(per(2:end) - per(1:end-1));   dT = dT(~isnan(dT));
        dA = abs(amp(2:end) - amp(1:end-1));   dA = dA(~isnan(dA));
        if numel(dT) >= 3, jit = mean(dT) / mean(per(voiced)); else, jit = NaN; end
        if numel(dA) >= 3, shi = mean(dA) / mean(amp(voiced)); else, shi = NaN; end
        pkc = min(pk(voiced), 0.999);
        hnr = mean(10*log10(pkc ./ (1 - pkc)));
        A.voice = [f0med, jit, shi, hnr + 20];
    else
        A.voice = nan(1, 4);
    end

    Pk = Pw(:, vad);
    f  = A.freqs(:);
    cent = (f' * Pk) ./ (sum(Pk, 1) + eps);
    cs   = cumsum(Pk, 1);
    [~, ri] = max(cs >= 0.85 * cs(end, :), [], 1);
    roll = A.freqs(ri);
    Pn   = Pk ./ (sum(Pk, 1) + eps);
    flux = sqrt(sum(diff(Pn, 1, 2).^2, 1));
    flat = exp(mean(log(Pk + eps), 1)) ./ (mean(Pk, 1) + eps);
    Xf   = x(idx(:, vad));
    zcr  = sum(abs(diff(sign(Xf), 1, 1)), 1) / (2*frameLen);
    A.spec = [mean(cent), mean(roll), mean(flat), mean(flux), mean(zcr), std(cent), std(roll)];
end

function y = spectralSubtract(x, Fs)
    x = x(:);  L = numel(x);
    N = 512;  H = 256;
    nFr = max(1, ceil((L - N) / H) + 1);
    Lp  = (nFr - 1) * H + N;
    xp  = [x; zeros(Lp - L, 1)];
    w   = sin(pi * ((0:N-1)' + 0.5) / N);
    idx = (1:N)' + (0:nFr-1) * H;
    X    = fft(xp(idx) .* w);
    mag2 = abs(X).^2;   ph = angle(X);
    [~, ord] = sort(sum(mag2, 1));
    nn = ord(1 : min(nFr, max(3, round(0.1*nFr))));
    Nm = mean(mag2(:, nn), 2);
    G2 = max(mag2 - 2*Nm, 0.02*mag2);
    Y  = sqrt(G2) .* exp(1j*ph);
    fr = real(ifft(Y)) .* w;
    y  = accumarray(idx(:), fr(:), [Lp 1]);
    y  = y(1:L);
end

function D = deltaCalc(M, N)
    T = size(M, 1);
    Mp = [repmat(M(1,:), N, 1); M; repmat(M(end,:), N, 1)];
    D = zeros(size(M));
    for n = 1:N
        D = D + n * (Mp((1:T)' + N + n, :) - Mp((1:T)' + N - n, :));
    end
    D = D / (2 * sum((1:N).^2));
end

function [f0, pk, amp, per] = pitchTrack(x, P, nF, stepLen, vad)
    pl = round(0.04 * P.Fs);
    f0 = nan(nF, 1);  pk = f0;  amp = f0;  per = f0;
    lagMin = floor(P.Fs / 400);
    lagMax = ceil(P.Fs / 70);
    for k = 1:nF
        if ~vad(k), continue; end
        i0 = (k-1) * stepLen;
        if i0 + pl > numel(x), break; end
        seg = x(i0 + (1:pl));  seg = seg - mean(seg);
        if sum(seg.^2) < 1e-6, continue; end
        r = real(ifft(abs(fft(seg, 2*pl)).^2));
        r = r(1:pl) / r(1);
        [p1, ii] = max(r(lagMin+1 : lagMax+1));
        L = lagMin + ii - 1;
        Lh = round(L/2);
        if Lh >= lagMin + 2
            [p2, i2] = max(r(Lh-1 : Lh+3));
            if p2 > 0.85 * p1, L = Lh - 3 + i2;  p1 = p2; end
        end
        if p1 > 0.35
            r0 = r(L+1);  rm = r(L);  rp = r(L+2);
            den = rm - 2*r0 + rp;  d = 0;
            if den < 0, d = max(-1, min(1, 0.5*(rm - rp)/den)); end
            Lr = L + d;
            f0(k) = P.Fs / Lr;  per(k) = Lr;  pk(k) = p1;  amp(k) = sqrt(mean(seg.^2));
        end
    end
end

function form = formantTrack(Yw, vad, P)
    nF = size(Yw, 2);
    form = nan(nF, 3);
    p = 16;
    R = real(ifft(abs(fft(Yw(:, vad), 1024)).^2));
    R = R(1:p+1, :);
    kidx = find(vad);
    for q = 1:numel(kidx)
        r = R(:, q);
        if r(1) < 1e-8, continue; end
        r(1) = r(1) * 1.0001;
        a = levinson(r, p);
        rts = roots(a);
        rts = rts(imag(rts) > 0.01);
        if isempty(rts), continue; end
        fr = angle(rts) * P.Fs / (2*pi);
        bw = -log(max(abs(rts), 1e-6)) * P.Fs / pi;
        ok = fr > 90 & fr < 5000 & bw < 400;
        fr = sort(fr(ok));
        if numel(fr) >= 3, form(kidx(q), :) = fr(1:3)'; end
    end
end

function a = levinson(r, p)
    a = zeros(1, p+1);  a(1) = 1;  e = r(1);
    for i = 1:p
        acc = r(i+1);
        for j = 1:i-1, acc = acc + a(j+1) * r(i-j+1); end
        k = -acc / e;
        anew = a;
        for j = 1:i-1, anew(j+1) = a(j+1) + k * a(i-j+1); end
        anew(i+1) = k;  a = anew;
        e = e * (1 - k^2);
        if e <= 0, break; end
    end
end

function [d, Dm, path] = dtwDist(A, B)
    A = A(1:2:end, :);  B = B(1:2:end, :);
    n = size(A, 1);  m = size(B, 1);
    Dm = sqrt(max(sum(A.^2, 2) + sum(B.^2, 2)' - 2*(A*B'), 0));
    Acc = inf(n+1, m+1);  Acc(1,1) = 0;
    for i = 1:n
        for j = 1:m
            Acc(i+1, j+1) = Dm(i,j) + min(min(Acc(i, j+1), Acc(i+1, j)), Acc(i, j));
        end
    end
    d = Acc(n+1, m+1) / (n + m);
    path = [];
    if nargout > 2
        i = n;  j = m;  path = [i j];
        while i > 1 || j > 1
            if i == 1
                j = j - 1;
            elseif j == 1
                i = i - 1;
            else
                [~, k] = min([Acc(i, j), Acc(i, j+1), Acc(i+1, j)]);
                if k == 1, i = i-1; j = j-1; elseif k == 2, i = i-1; else, j = j-1; end
            end
            path(end+1, :) = [i j];
        end
    end
end

function d = relDist(a, b)
    v = ~isnan(a) & ~isnan(b);
    if ~any(v), d = NaN; return; end
    r = abs(a(v) - b(v)) ./ ((abs(a(v)) + abs(b(v)))/2 + 1e-6);
    d = sqrt(mean(min(r, 2).^2));
end

function d = featureDistances(A, B)
    d = [dtwDist(A.F, B.F), relDist(A.form, B.form), relDist(A.voice, B.voice), relDist(A.spec, B.spec)];
end

function model = buildModel(enr, P)
    n = numel(enr);  pairD = [];
    for i = 1:n-1
        for j = i+1:n
            pairD(end+1, :) = featureDistances(enr{i}, enr{j});
        end
    end
    mu = mean(pairD, 1);
    if size(pairD, 1) > 1, sd = std(pairD, 0, 1); else, sd = zeros(1, 4); end
    sdEff = min(max(sd, 0.06 * abs(mu)), 0.15 * abs(mu));
    sdEff(sdEff < 1e-6 | isnan(sdEff)) = 1e-6;
    w = [0.55 0.15 0.15 0.15];
    bad = any(isnan(pairD), 1);
    w(bad) = 0;  mu(bad) = 0;
    model.pairD = pairD;  model.mu = mu;  model.sd = sdEff;  model.w = w;
    model.warn = size(pairD, 1) > 1 && ~isnan(sd(1)) && sd(1) > 0.25 * abs(mu(1));
end

function sc = scoreTest(A, model, enr)
    n = numel(enr);  D = zeros(n, 4);
    for i = 1:n, D(i, :) = featureDistances(A, enr{i}); end
    dm = mean(D, 1, 'omitnan');
    z  = (dm - model.mu) ./ model.sd;
    valid = model.w > 0 & ~isnan(z);
    if ~any(valid), error('No usable features in this recording.'); end
    sc.fused = sum(model.w(valid) .* z(valid)) / sum(model.w(valid));
    sc.D = D;  sc.dm = dm;  sc.z = z;
    [~, sc.best] = min(D(:, 1));
end

function fb = melFilterBank(numFilters, NFFT, fs)
    hz2mel = @(f) 2595 * log10(1 + f/700);
    mel2hz = @(m) 700 * (10.^(m/2595) - 1);
    melPts = linspace(hz2mel(0), hz2mel(fs/2), numFilters + 2);
    bins   = floor((NFFT + 1) * mel2hz(melPts) / fs) + 1;
    fb = zeros(numFilters, NFFT/2 + 1);
    for m = 1:numFilters
        l = bins(m); c = bins(m+1); r = bins(m+2);
        for k = l:c, fb(m,k) = (k - l) / max(c - l, 1); end
        for k = c:r, fb(m,k) = (r - k) / max(r - c, 1); end
    end
end

function D = dctMatrix(N, K)
    D = zeros(K, N);
    for k = 0:K-1
        for n = 0:N-1
            D(k+1, n+1) = cos(pi * k * (n + 0.5) / N);
        end
    end
    D = D * sqrt(2/N);
    D(1,:) = D(1,:) / sqrt(2);
end

function sig = loadAudio(fname, Fs_target)
    if ~isfile(fname), error('File not found: %s', fname); end
    try
        [x, fs] = audioread(fname);
    catch
        [x, fs] = readWithFFmpeg(fname, Fs_target);
    end
    if size(x, 2) > 1, x = mean(x, 2); end
    sig = resampleTo(x, fs, Fs_target);
end

function [x, fs] = readWithFFmpeg(fname, Fs_target)
    [status, ~] = system('ffmpeg -version');
    if status ~= 0
        error(['MATLAB cannot read this file and FFmpeg is not installed. ' ...
               'Install FFmpeg (ffmpeg.org) or convert the file to wav/mp3.']);
    end
    tmp = [tempname, '.wav'];
    [status, msg] = system(sprintf('ffmpeg -y -loglevel error -i "%s" -ac 1 -ar %d "%s"', fname, Fs_target, tmp));
    if status ~= 0 || ~isfile(tmp), error('FFmpeg could not convert the file: %s', msg); end
    [x, fs] = audioread(tmp);
    delete(tmp);
end

function y = resampleTo(x, fs, fsTarget)
    if fs == fsTarget, y = x(:); return; end
    tOld = (0:numel(x)-1) / fs;
    tNew = 0 : 1/fsTarget : tOld(end);
    y = interp1(tOld, x, tNew, 'linear')';
end