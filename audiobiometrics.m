function audio_biometrics_pro()
%% ========================================================================
%  AUDIO BIOMETRICS PRO  -  PURE DSP SPEAKER VERIFICATION (NO AI / ML)
%
%  Signal-processing techniques used:
%    * DC removal, peak normalization, pre-emphasis filter
%    * Framing + Hamming window + FFT power spectrum
%    * Energy-based voice activity detection (VAD) + median smoothing
%    * 26-filter Mel filter bank -> log -> DCT -> MFCC
%    * CMVN (cepstral mean & variance normalization) -> removes mic/room effect
%    * Delta coefficients (time derivative of MFCC)        -> 24 features/frame
%    * Pitch (F0) tracking by autocorrelation
%    * Long-term average spectrum (LTAS)
%    * Dynamic Time Warping (DTW) to compare two utterances
%    * Threshold auto-calibrated from YOUR enrollment recordings (statistics)
%    * FAR / FRR / EER / ROC evaluation
%
%  USAGE
%    1. Enroll the speaker: record or load 2-5 samples of the SAME phrase
%    2. Record or load a TEST sample (same phrase)
%    3. Press VERIFY  -> ACCESS GRANTED / DENIED + full dashboard
%  Run with:   audio_biometrics_pro        (base MATLAB, R2016b or newer)
%  ========================================================================

    % ---------------- parameters ----------------------------------------
    P.Fs = 16000;   P.frameMs = 25;   P.stepMs = 10;   P.alpha = 0.97;
    P.nFilt = 26;   P.nCoef = 13;     P.NFFT = 512;
    P.maxSec = 12;                    % analyse at most 12 s per recording
    P.wPitch = 0.04;                  % weight of pitch difference in final score
    P.fbank  = melFilterBank(P.nFilt, P.NFFT, P.Fs);
    P.dctMat = dctMatrix(P.nFilt, P.nCoef);
    Fs = P.Fs;

    % ---------------- shared state --------------------------------------
    enr = {};  enrNames = {};          % analysed enrollment recordings
    testSig = [];  testName = '';
    Tfixed = [];                       % threshold set from EER (optional)
    rec = [];  tmr = [];  recMode = '';  t0 = [];

    % ---------------- window --------------------------------------------
    fig = figure('Name', 'Audio Biometrics PRO - Pure DSP Speaker Verification', ...
        'NumberTitle', 'off', 'MenuBar', 'none', 'ToolBar', 'none', ...
        'Position', [180 50 920 660], 'CloseRequestFcn', @onClose);

    axWave = axes('Parent', fig, 'Units', 'pixels', 'Position', [60 465 800 165]);
    hLine = plot(axWave, 0, 0, 'b'); grid(axWave, 'on');
    ylim(axWave, [-1 1]); xlabel(axWave, 'Time (s)'); ylabel(axWave, 'Amplitude');
    title(axWave, 'Waveform (shows live while recording)');

    btnRecEnr  = mkBtn('Record Enrollment', [60  405 190 42], @(~,~) startRec('enroll'));
    btnRecTest = mkBtn('Record Test',       [260 405 190 42], @(~,~) startRec('test'));
    btnStop    = mkBtn('STOP',              [460 405 190 42], @(~,~) stopRec());
    set(btnStop, 'Enable', 'off', 'ForegroundColor', [0.8 0 0], 'FontWeight', 'bold');
    btnReset   = mkBtn('Reset All',         [660 405 200 42], @(~,~) resetAll());

    btnLoadEnr  = mkBtn('Load Enrollment File(s)', [60  357 190 38], @(~,~) loadEnroll());
    btnLoadTest = mkBtn('Load Test File',          [260 357 190 38], @(~,~) loadTest());

    txtEnr  = mkTxt([60 322 800 24], 'Enrollment: none yet (record / load 2 to 5 samples of the SAME phrase)');
    txtTest = mkTxt([60 297 800 24], 'Test voice: not provided yet');
    txtCal  = mkTxt([60 272 800 24], 'Threshold: will be auto-calibrated from your enrollment samples');

    btnVerify = mkBtn('VERIFY', [60 205 800 52], @(~,~) verify());
    set(btnVerify, 'FontSize', 15, 'FontWeight', 'bold');

    txtResult = uicontrol(fig, 'Style', 'text', 'FontSize', 18, 'FontWeight', 'bold', ...
        'Position', [60 130 800 60], 'String', 'Result will appear here', ...
        'BackgroundColor', [0.94 0.94 0.94]);

    uicontrol(fig, 'Style', 'text', 'FontSize', 10, 'HorizontalAlignment', 'left', ...
        'Position', [60 20 800 100], 'String', sprintf(['TIPS:  say the same short phrase every time (3 to 5 s), ' ...
        'same microphone, quiet room.\nEnroll 3 to 5 samples. The threshold is calibrated automatically ' ...
        'from your enrollment recordings.\nThen record / load a test sample and press VERIFY.']));

    % ====================================================================
    %                         UI HELPERS / CALLBACKS
    % ====================================================================
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
        set([btnRecEnr btnRecTest btnLoadEnr btnLoadTest btnVerify btnReset], 'Enable', s);
        if isIdle, set(btnStop, 'Enable', 'off'); else, set(btnStop, 'Enable', 'on'); end
    end

    function startRec(m)
        recMode = m;
        try
            rec = audiorecorder(Fs, 16, 1);
            record(rec);                              % <- recording starts here
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
        n = numel(x);  w = min(n, 5*Fs);
        set(hLine, 'XData', ((n-w):(n-1))/Fs, 'YData', x(end-w+1:end));
        xlim(axWave, [(n-w)/Fs, max((n-w)/Fs + 5, n/Fs)]);
        ylim(axWave, [-max(0.05, 1.1*max(abs(x(end-w+1:end)))), max(0.05, 1.1*max(abs(x(end-w+1:end))))]);
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
            A = analyzeVoice(x, P);
        catch ME
            errordlg(ME.message, 'Enrollment error'); return;
        end
        enr{end+1} = A;  enrNames{end+1} = name;  %#ok<AGROW>
        showWave(x, sprintf('Enrollment sample "%s" captured (%.1f s)', name, numel(x)/Fs), [0 0.55 0]);
        refreshStatus();
    end

    function setTest(x, name)
        testSig = x(:);  testName = name;
        showWave(testSig, sprintf('Test voice captured (%.1f s)', numel(testSig)/Fs), [0 0.4 0.8]);
        set(txtTest, 'String', sprintf('Test voice:  %s  (%.1f s)  OK', name, numel(testSig)/Fs));
    end

    function resetAll()
        enr = {};  enrNames = {};  testSig = [];  Tfixed = [];
        set(hLine, 'XData', 0, 'YData', 0, 'Color', 'b');
        title(axWave, 'Waveform (shows live while recording)', 'Color', 'k');
        set(txtTest, 'String', 'Test voice: not provided yet');
        set(txtResult, 'String', 'Result will appear here', 'ForegroundColor', 'k', ...
            'BackgroundColor', [0.94 0.94 0.94]);
        refreshStatus();
    end

    function refreshStatus()
        n = numel(enr);
        if n == 0
            set(txtEnr, 'String', 'Enrollment: none yet (record / load 2 to 5 samples of the SAME phrase)');
            set(txtCal, 'String', 'Threshold: will be auto-calibrated from your enrollment samples');
            return;
        end
        set(txtEnr, 'String', sprintf('Enrollment: %d sample(s)  [%s]', n, strjoin(enrNames, ', ')));
        if n < 2
            set(txtCal, 'String', 'Add at least ONE more enrollment sample to calibrate the threshold.');
        else
            [mu, sd, T] = calibrate();
            s = sprintf('Auto-calibration: genuine score mean = %.2f, std = %.2f  ->  threshold T = %.2f', mu, sd, T);
            if ~isempty(Tfixed), s = sprintf('%s   |   EER threshold %.2f in use', s, Tfixed); end
            set(txtCal, 'String', s);
        end
    end

    % ====================================================================
    %                  SCORING / CALIBRATION (statistics only)
    % ====================================================================
    function st = semitones(a, b)
        if isnan(a) || isnan(b), st = 0; else, st = abs(12*log2(a/b)); end
    end

    function f0e = enrollF0()
        v = cellfun(@(e) e.f0, enr);  v = v(~isnan(v));
        if isempty(v), f0e = NaN; else, f0e = median(v); end
    end

    function [mu, sd, T, pairS] = calibrate()
        % Scores between enrollment samples = typical "same speaker" score
        n = numel(enr);  pairS = [];
        for i = 1:n-1
            for j = i+1:n
                d  = dtwDist(enr{i}.F, enr{j}.F);
                st = semitones(enr{i}.f0, enr{j}.f0);
                pairS(end+1) = d * (1 + P.wPitch*st); %#ok<AGROW>
            end
        end
        mu = mean(pairS);
        if numel(pairS) > 1, sd = std(pairS); else, sd = 0; end
        k = 2;                                    % fixed strictness (automatic)
        T = mu + k * max(sd, 0.08*mu);
    end

    function [S, dAll, best, st, f0e] = scoreAgainstEnroll(A)
        n = numel(enr);  dAll = zeros(1, n);
        for i = 1:n, dAll(i) = dtwDist(A.F, enr{i}.F); end
        f0e = enrollF0();
        st  = semitones(A.f0, f0e);
        S   = mean(dAll) * (1 + P.wPitch*st);      % fused score (smaller = more similar)
        [~, best] = min(dAll);
    end

    function T = currentThreshold()
        [~, ~, T] = calibrate();
        if ~isempty(Tfixed), T = Tfixed; end
    end

    % ====================================================================
    %                              VERIFY
    % ====================================================================
    function verify()
        if numel(enr) < 2
            warndlg('Provide at least 2 enrollment samples first.'); return;
        end
        if isempty(testSig)
            warndlg('Provide a test voice first.'); return;
        end
        set(txtResult, 'String', 'Analysing ...', 'ForegroundColor', 'k'); drawnow;
        try
            A = analyzeVoice(testSig, P);
            [mu, sd, T, pairS] = calibrate();
            if ~isempty(Tfixed), T = Tfixed; end
            [S, dAll, best, st, f0e] = scoreAgainstEnroll(A);
        catch ME
            errordlg(ME.message, 'Processing error'); return;
        end
        ok   = S <= T;
        conf = 100 / (1 + exp(8*(S/T - 1)));       % heuristic confidence (%)
        if ok
            set(txtResult, 'ForegroundColor', [0 0.5 0], 'String', ...
                sprintf('ACCESS GRANTED  -  same speaker   (score %.2f <= T %.2f)', S, T));
        else
            set(txtResult, 'ForegroundColor', [0.8 0 0], 'String', ...
                sprintf('ACCESS DENIED  -  different speaker   (score %.2f > T %.2f)', S, T));
        end

        fprintf('\n================ VERIFICATION REPORT ================\n');
        fprintf('Enrollment samples        : %d\n', numel(enr));
        fprintf('Genuine score mean / std  : %.3f / %.3f\n', mu, sd);
        fprintf('Threshold T               : %.3f\n', T);
        fprintf('DTW distance per enroll   : %s\n', mat2str(round(dAll, 3)));
        fprintf('Pitch enroll / test (Hz)  : %.1f / %.1f  (diff %.2f semitones)\n', f0e, A.f0, st);
        fprintf('FINAL SCORE               : %.3f   ->  %s\n', S, ternary(ok, 'MATCH', 'NO MATCH'));
        fprintf('Confidence (heuristic)    : %.1f %%\n', conf);
        fprintf('=====================================================\n');

        showDashboard(A, best, S, T, pairS, f0e, ok, conf, dAll, st);
    end

    % ====================================================================
    %                       DASHBOARD (many plots)
    % ====================================================================
    function showDashboard(A, best, S, T, pairS, f0e, ok, conf, dAll, st)
        f2 = figure(901); clf(f2);
        set(f2, 'Name', 'Verification Dashboard', 'NumberTitle', 'off', ...
            'Position', [60 40 1350 800]);
        colormap(f2, 'jet');
        t = (0:numel(A.x)-1)/Fs;

        subplot(3,3,1);
        plot(t, A.x, 'b'); hold on; stairs(A.tf, double(A.vad)*0.9, 'r', 'LineWidth', 1.2);
        grid on; xlabel('Time (s)'); ylabel('Amplitude');
        title('1. Test waveform + speech detection (red)');

        subplot(3,3,2);
        imagesc(A.tf, A.freqs, A.Sdb); axis xy;
        mx = max(A.Sdb(:)); caxis([mx-70 mx]);
        xlabel('Time (s)'); ylabel('Frequency (Hz)'); title('2. Spectrogram (FFT of every frame)');

        subplot(3,3,3);
        plot(A.tf, A.f0track, 'b.'); hold on; grid on;
        if ~isnan(f0e), plot([A.tf(1) A.tf(end)], [f0e f0e], 'r--', 'LineWidth', 1.5); end
        ylim([50 450]); xlabel('Time (s)'); ylabel('F0 (Hz)');
        title(sprintf('3. Pitch (autocorrelation). Test %.0f Hz | enroll %.0f Hz', A.f0, f0e));

        subplot(3,3,4);
        plot(A.freqs, P.fbank', 'LineWidth', 1); grid on;
        xlabel('Frequency (Hz)'); title('4. Mel filter bank (26 filters)');

        subplot(3,3,5);
        imagesc(A.M'); axis xy; xlabel('Speech frame'); ylabel('MFCC c1..c12');
        title('5. MFCC heat-map (after CMVN)'); colorbar;

        subplot(3,3,6);
        [~, Dm, path] = dtwDist(A.F, enr{best}.F);
        imagesc(Dm); axis xy; hold on;
        plot(path(:,2), path(:,1), 'w', 'LineWidth', 2);
        xlabel(sprintf('enrollment "%s" frame (/2)', enrNames{best})); ylabel('test frame (/2)');
        title('6. DTW cost matrix + optimal alignment path');

        subplot(3,3,7);
        n = numel(pairS);
        bar(1:n, pairS, 'FaceColor', [0.2 0.5 0.9]); hold on;
        bar(n+1, S, 'FaceColor', ternaryC(ok));
        plot([0 n+2], [T T], 'k--', 'LineWidth', 2);
        grid on; xlim([0 n+2]); ylabel('Score (smaller = more similar)');
        title('7. Enrollment scores (blue) | TEST (colour) | threshold');
        set(gca, 'XTick', 1:n+1, 'XTickLabel', [repmat({'enr'}, 1, n), {'TEST'}]);

        subplot(3,3,8);
        L = mean(cell2mat(cellfun(@(e) e.ltas, enr, 'UniformOutput', false)), 2);
        plot(A.freqs, L, 'b', 'LineWidth', 1.5); hold on;
        plot(A.freqs, A.ltas, 'r', 'LineWidth', 1.5); grid on;
        xlabel('Frequency (Hz)'); ylabel('dB'); legend('Enrollment', 'Test');
        title('8. Long-term average spectrum (voice colour)');

        subplot(3,3,9);
        cla; axis([0 1 0 1]); axis off;
        rectangle('Position', [0 0 1 1], 'FaceColor', ternaryC(ok), 'EdgeColor', 'none');
        if ok, v = 'ACCESS GRANTED'; else, v = 'ACCESS DENIED'; end
        text(0.5, 0.82, v, 'Color', 'w', 'FontSize', 20, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
        text(0.5, 0.62, sprintf('Score %.2f   Threshold %.2f', S, T), 'Color', 'w', 'FontSize', 13, 'HorizontalAlignment', 'center');
        text(0.5, 0.46, sprintf('Confidence (heuristic): %.0f %%', conf), 'Color', 'w', 'FontSize', 13, 'HorizontalAlignment', 'center');
        text(0.5, 0.30, sprintf('DTW per enrollment: %s', mat2str(round(dAll, 2))), 'Color', 'w', 'FontSize', 10, 'HorizontalAlignment', 'center');
        text(0.5, 0.14, sprintf('Pitch difference: %.2f semitones', st), 'Color', 'w', 'FontSize', 10, 'HorizontalAlignment', 'center');
    end

    % ====================================================================
    %                  EVALUATION: FAR / FRR / EER / ROC
    % ====================================================================
    function evaluate()
        if numel(enr) < 2
            warndlg('Enroll at least 2 samples first.'); return;
        end
        [fg, pg] = uigetfile(audioFilter(), 'Select GENUINE test files (same speaker as enrollment)', 'MultiSelect', 'on');
        if isequal(fg, 0), return; end
        [fi, pi_] = uigetfile(audioFilter(), 'Select IMPOSTOR test files (other speakers)', 'MultiSelect', 'on');
        if isequal(fi, 0), return; end
        if ischar(fg), fg = {fg}; end
        if ischar(fi), fi = {fi}; end
        set(txtResult, 'String', 'Evaluating ... please wait', 'ForegroundColor', 'k'); drawnow;

        sg = scoreFiles(fullfile(pg, fg));
        si = scoreFiles(fullfile(pi_, fi));
        if isempty(sg) || isempty(si)
            errordlg('Need at least one valid genuine and one valid impostor file.'); return;
        end

        allS = [sg(:); si(:)];
        th  = linspace(0.9*min(allS), 1.1*max(allS), 500);
        FAR = arrayfun(@(t) mean(si <= t), th);    % impostors wrongly accepted
        FRR = arrayfun(@(t) mean(sg >  t), th);    % genuine wrongly rejected
        [~, ie] = min(abs(FAR - FRR));
        EER  = (FAR(ie) + FRR(ie)) / 2;   tEER = th(ie);
        Tcur = currentThreshold();
        acc  = (sum(sg <= Tcur) + sum(si > Tcur)) / (numel(sg) + numel(si));

        fprintf('\n=========== EVALUATION ===========\n');
        fprintf('Genuine trials  : %d\nImpostor trials : %d\n', numel(sg), numel(si));
        fprintf('EER             : %.2f %%  (threshold %.3f)\n', 100*EER, tEER);
        fprintf('Accuracy @ current T=%.3f : %.1f %%\n', Tcur, 100*acc);
        fprintf('FAR @ current T : %.1f %%\nFRR @ current T : %.1f %%\n', ...
                100*mean(si <= Tcur), 100*mean(sg > Tcur));
        fprintf('==================================\n');

        f3 = figure(902); clf(f3);
        set(f3, 'Name', 'Evaluation: FAR / FRR / EER / ROC', 'NumberTitle', 'off', 'Position', [100 100 1300 420]);
        subplot(1,3,1);
        histogram(sg, 10, 'FaceColor', [0.1 0.7 0.2]); hold on;
        histogram(si, 10, 'FaceColor', [0.85 0.15 0.15]);
        yl = ylim; plot([tEER tEER], yl, 'k--', 'LineWidth', 2);
        grid on; xlabel('Score'); ylabel('Count'); legend('Genuine', 'Impostor', 'EER threshold');
        title('Score distributions');
        subplot(1,3,2);
        plot(th, 100*FAR, 'r', th, 100*FRR, 'b', 'LineWidth', 1.8); hold on;
        plot(tEER, 100*EER, 'ko', 'MarkerSize', 10, 'MarkerFaceColor', 'y'); grid on;
        xlabel('Threshold'); ylabel('Error (%)'); legend('FAR', 'FRR', sprintf('EER = %.1f%%', 100*EER));
        title('FAR / FRR vs threshold');
        subplot(1,3,3);
        plot(100*FAR, 100*(1-FRR), 'm', 'LineWidth', 2); hold on; plot([0 100], [0 100], 'k:'); grid on;
        xlabel('False accept rate (%)'); ylabel('True accept rate (%)'); title('ROC curve');

        ch = questdlg(sprintf('EER = %.1f %% at threshold %.2f.\nUse this threshold for verification?', 100*EER, tEER), ...
                      'Calibration', 'Yes', 'No', 'Yes');
        if strcmp(ch, 'Yes'), Tfixed = tEER; end
        set(txtResult, 'String', sprintf('Evaluation done:  EER = %.1f %%', 100*EER), 'ForegroundColor', 'k');
        refreshStatus();
    end

    function s = scoreFiles(files)
        s = nan(1, numel(files));
        for q = 1:numel(files)
            try
                Aq = analyzeVoice(loadAudio(files{q}, Fs), P);
                s(q) = scoreAgainstEnroll(Aq);
            catch ME
                fprintf('Skipped %s: %s\n', files{q}, ME.message);
            end
        end
        s = s(~isnan(s));
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


%% ========================================================================
%                          DSP CORE (local functions)
%  ========================================================================

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end

function c = ternaryC(ok)
    if ok, c = [0.10 0.60 0.20]; else, c = [0.78 0.12 0.12]; end
end

function A = analyzeVoice(x, P)
% Full DSP analysis of one recording.
    x = x(:);
    x = x(1 : min(numel(x), round(P.maxSec * P.Fs)));
    x = x - mean(x);                                   % DC removal
    if max(abs(x)) < 1e-4
        error('The recording is silent. Check microphone / file.');
    end
    x = x / (max(abs(x)) + eps);                       % normalization -> [-1,1]
    y = [x(1); x(2:end) - P.alpha * x(1:end-1)];       % pre-emphasis

    frameLen = round(P.Fs * P.frameMs / 1000);         % 400 samples
    stepLen  = round(P.Fs * P.stepMs  / 1000);         % 160 samples
    nF = 1 + floor((numel(y) - frameLen) / stepLen);
    if nF < 30, error('Recording too short (need about 0.5 s or more).'); end

    idx = (1:frameLen)' + (0:nF-1) * stepLen;          % framing (matrix form)
    w   = 0.54 - 0.46 * cos(2*pi*(0:frameLen-1)' / (frameLen-1));   % Hamming
    Yw  = y(idx) .* w;

    X  = fft(Yw, P.NFFT);                              % FFT of all frames
    Pw = abs(X(1:P.NFFT/2+1, :)).^2;                   % power spectrum
    E  = max(P.fbank * Pw, eps);                       % Mel filter-bank energies
    C  = P.dctMat * log(E);                            % log + DCT -> MFCC (13 x nF)

    % ---- voice activity detection (energy based + smoothing) -----------
    eDB = 10*log10(sum(Yw.^2, 1)' + eps);
    s = sort(eDB);
    noiseFloor = s(max(1, round(0.1*nF)));
    hi         = s(max(1, round(0.9*nF)));
    vad = eDB > noiseFloor + 0.3*(hi - noiseFloor);
    vad = movmean(double(vad), 7) > 0.5;
    if sum(vad) < 30, vad = eDB >= median(eDB); end
    if sum(vad) < 30, error('Not enough speech detected.'); end

    % ---- features: c1..c12 + CMVN + deltas -----------------------------
    M = C(2:end, vad)';                                % drop c0 (loudness)
    M = (M - mean(M, 1)) ./ (std(M, 0, 1) + eps);      % CMVN
    D = deltaCalc(M, 2);                               % delta coefficients
    A.F = [M D];                                       % 24 features per frame
    A.M = M;

    A.x = x;  A.vad = vad;
    A.tf = ((0:nF-1) * stepLen + frameLen/2) / P.Fs;
    A.freqs = (0:P.NFFT/2) * P.Fs / P.NFFT;
    A.Sdb = 10*log10(Pw + eps);
    A.ltas = mean(A.Sdb(:, vad), 2);                   % long-term average spectrum

    A.f0track = pitchTrack(x, P, nF, stepLen, vad);    % autocorrelation pitch
    v = A.f0track(~isnan(A.f0track));
    if isempty(v), A.f0 = NaN; else, A.f0 = median(v); end
end

function D = deltaCalc(M, N)
% Regression-based delta (time derivative) of feature matrix M (frames x dims)
    T = size(M, 1);
    Mp = [repmat(M(1,:), N, 1); M; repmat(M(end,:), N, 1)];
    D = zeros(size(M));
    for n = 1:N
        D = D + n * (Mp((1:T)' + N + n, :) - Mp((1:T)' + N - n, :));
    end
    D = D / (2 * sum((1:N).^2));
end

function f0 = pitchTrack(x, P, nF, stepLen, vad)
% Pitch (F0) by autocorrelation on 40 ms segments, search range 70-400 Hz
    pl = round(0.04 * P.Fs);
    f0 = nan(nF, 1);
    lagMin = floor(P.Fs / 400);
    lagMax = ceil(P.Fs / 70);
    for k = 1:nF
        if ~vad(k), continue; end
        i0 = (k-1) * stepLen;
        if i0 + pl > numel(x), break; end
        seg = x(i0 + (1:pl));  seg = seg - mean(seg);
        if sum(seg.^2) < 1e-6, continue; end
        r = real(ifft(abs(fft(seg, 2*pl)).^2));        % autocorrelation via FFT
        r = r(1:pl) / r(1);
        [pk, ii] = max(r(lagMin+1 : lagMax+1));
        if pk > 0.35                                   % voiced if strong periodicity
            f0(k) = P.Fs / (lagMin + ii - 1);
        end
    end
end

function [d, Dm, path] = dtwDist(A, B)
% Dynamic Time Warping distance between two feature sequences
% (rows = frames). Returns length-normalized distance, cost matrix and path.
    A = A(1:2:end, :);  B = B(1:2:end, :);             % speed-up (20 ms hop)
    n = size(A, 1);  m = size(B, 1);
    Dm = sqrt(max(sum(A.^2, 2) + sum(B.^2, 2)' - 2*(A*B'), 0));   % Euclidean
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
            path(end+1, :) = [i j]; %#ok<AGROW>
        end
    end
end

function fb = melFilterBank(numFilters, NFFT, fs)
% Triangular Mel filters, m = 2595*log10(1 + f/700)
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
% DCT-II matrix: first K coefficients of an N-point sequence
    D = zeros(K, N);
    for k = 0:K-1
        for n = 0:N-1
            D(k+1, n+1) = cos(pi * k * (n + 0.5) / N);
        end
    end
    D = D * sqrt(2/N);
    D(1,:) = D(1,:) / sqrt(2);
end

%% ------------------------ audio input helpers ---------------------------
function sig = loadAudio(fname, Fs_target)
% Read ANY audio format -> mono -> resampled
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